; =====================================================================
;  PI20.ASM  --  Intel 4004: compute pi to 20 decimal places
;               3.14159265358979323846
; ---------------------------------------------------------------------
;  Algorithm: Rabinowitz-Wagon decimal spigot.
;     a[i] = 2 for i = 1..L          (L = 81 terms, enough for 24 digits)
;     repeat 24 times:
;        q = 0
;        for i = L downto 1:
;           x    = 10*a[i] + q*i
;           d    = 2i-1   (d = 10 when i = 1)
;           a[i] = x mod d
;           q    = x div d
;        emit q                   (q may be 10 -> carry fixed up later)
;  24 digits are computed and 21 are printed (3 + 20 decimals); the
;  extra 3 are guard digits so pending carries can't corrupt digit 20.
;
;  4004-specific tricks
;   * No multiply/divide: x div d is done by repeated subtraction
;     (q never exceeds 18 here), and 10*a by ten additions.
;   * q*i is never multiplied.  Every time the divide loop at index i
;     takes d out of x, it adds (i-1) to C.  When the loop ends,
;     C = q*(i-1), which is exactly the carry term the next index needs.
;   * Subtraction is done by adding -d (two's complement held in ND),
;     so only ADD is used and the carry flag means "no borrow".
;     ND starts at -161 and steps by +2 as i falls.
;   * a[i] is 8 bits wide. Its low nibble lives in RAM bank 0 and its
;     high nibble in bank 1, both at address i-1. So the SRC
;     pointer P0 holds i-1, which is also the value added to C.
;
;  Largest intermediate values (checked): x <= 2554, C <= 1440 (12 bits)
;
;  Register map
;   P0 = R0:R1     p = i-1 = RAM address of a[i]   (R0 high, R1 low)
;   R2 R3 R4       X  working value (low, mid, high nibble)
;   R5 R6 R7       ND = -d, 12-bit two's complement
;   R8 R9 R10      C  = accumulated carry term q*(i-1)
;   R11            loop counter / final quotient (digit)
;   P6 = R12:R13   digit pointer in RAM bank 2
;   R14 R15        a[i] low / high nibble, scratch
;
;  RAM:  bank 0 = a[] low nibbles, bank 1 = a[] high nibbles,
;        bank 2 chars 0x08..0x1F = the 24 digits (0x08 = "3")
;  Output: the 21 digits are written in order to ROM I/O port 0 (WRR).
; =====================================================================

        ORG 0

; ---- initialise a[] = 2 (fill whole bank: lo=2, hi=0) --------------
start:  FIM  P0, 0x00
fill:   LDM  0
        DCL
        SRC  P0
        LDM  2
        WRM                 ; bank0[p] = 2
        LDM  1
        DCL
        SRC  P0
        LDM  0
        WRM                 ; bank1[p] = 0
        ISZ  R1, fill
        ISZ  R0, fill

        FIM  P6, 0x08       ; first digit goes to bank2[0x08]

; ---- one pass of the spigot = one digit -------------------------------
digit:  FIM  P0, 80         ; p = 80  ->  i = 81
        LDM  15             ; ND = -161 = 0xF5F
        XCH  R5
        LDM  5
        XCH  R6
        LDM  15
        XCH  R7
        FIM  P4, 0x00       ; C = 0
        LDM  0
        XCH  R10

step:   JMS  loadx          ; X = 10*a[i] + C ;  C = 0

div:    CLC                 ; trial: does X + ND carry?  (X >= d)
        LD   R2
        ADD  R5
        LD   R3
        ADD  R6
        LD   R4
        ADD  R7
        JCN  10, done       ; no carry -> X < d, X is the remainder
        CLC                 ; X = X - d
        LD   R2
        ADD  R5
        XCH  R2
        LD   R3
        ADD  R6
        XCH  R3
        LD   R4
        ADD  R7
        XCH  R4
        CLC                 ; C = C + p   (builds q*(i-1))
        LD   R8
        ADD  R1
        XCH  R8
        LD   R9
        ADD  R0
        XCH  R9
        LDM  0
        ADD  R10
        XCH  R10
        JUN  div

done:   JMS  storex         ; a[i] = remainder
        CLC                 ; ND = ND + 2   (d = 2i-1 shrinks by 2)
        LDM  2
        ADD  R5
        XCH  R5
        LDM  0
        ADD  R6
        XCH  R6
        LDM  0
        ADD  R7
        XCH  R7
        LD   R1             ; p = p - 1
        DAC
        XCH  R1
        JCN  2, nob         ; carry set = no borrow
        LD   R0
        DAC
        XCH  R0
nob:    LD   R0             ; loop while p != 0  (i >= 2)
        JCN  12, step
        LD   R1
        JCN  12, step

; ---- i = 1 : divide by 10, quotient is the new digit ---------------
        JMS  loadx
        LDM  6              ; ND = -10 = 0xFF6
        XCH  R5
        LDM  15
        XCH  R6
        LDM  15
        XCH  R7
        LDM  0
        XCH  R11            ; q = 0
dv1:    CLC
        LD   R2
        ADD  R5
        LD   R3
        ADD  R6
        LD   R4
        ADD  R7
        JCN  10, dn1
        CLC
        LD   R2
        ADD  R5
        XCH  R2
        LD   R3
        ADD  R6
        XCH  R3
        LD   R4
        ADD  R7
        XCH  R4
        INC  R11
        JUN  dv1
dn1:    JMS  storex         ; a[1] = x mod 10
        LDM  2              ; bank2[ptr] = digit (0..10)
        DCL
        SRC  P6
        LD   R11
        WRM
        ISZ  R13, more      ; ptr++ ; stop after 0x1F (24 digits)
        INC  R12
        LD   R12
        RAR                 ; R12 = 1 -> CY=1 continue, R12 = 2 -> stop
        JCN  10, fixup
more:   JUN  digit

; ---- carry fix-up: any digit of 10 becomes 0 and carries left --------
fixup:  FIM  P6, 0x1F
        LDM  2
        DCL
fix:    SRC  P6
        RDM
        XCH  R14
        CLC
        LDM  6
        ADD  R14            ; carry iff digit >= 10, A = digit-10
        JCN  10, nofix
        WRM
        JMS  dec6
        SRC  P6
        RDM
        IAC                 ; previous digit + 1
        WRM
        JUN  fixchk
nofix:  JMS  dec6
fixchk: LD   R12            ; stop when ptr reaches 0x08
        JCN  12, fix
        CLC
        LDM  8
        ADD  R13
        JCN  12, fix

; ---- output 21 digits (bank2 0x08..0x1C) to ROM port 0 ---------------
        FIM  P6, 0x08
        FIM  P7, 0x00
out:    LDM  2
        DCL
        SRC  P6
        RDM
        SRC  P7             ; select ROM chip 0
        WRR                 ; port 0 <- digit
        ISZ  R13, outchk
        INC  R12
outchk: LD   R12
        JCN  4, out         ; ptr < 0x10 -> keep going
        CLC
        LDM  3
        ADD  R13            ; zero only when R13 = 13 (ptr = 0x1D)
        JCN  12, out
halt:   JUN  halt

; ---- subroutines ------------------------------------------------------
; loadx: X = 10*a[p] + C ; C = 0
loadx:  LDM  0
        DCL
        SRC  P0
        RDM
        XCH  R14            ; a low
        LDM  1
        DCL
        SRC  P0
        RDM
        XCH  R15            ; a high
        LD   R8             ; X = C
        XCH  R2
        LD   R9
        XCH  R3
        LD   R10
        XCH  R4
        FIM  P4, 0x00       ; C = 0
        LDM  0
        XCH  R10
        LDM  6              ; add a ten times (ISZ 6 -> 16)
        XCH  R11
mul:    CLC
        LD   R2
        ADD  R14
        XCH  R2
        LD   R3
        ADD  R15
        XCH  R3
        LDM  0
        ADD  R4
        XCH  R4
        ISZ  R11, mul
        BBL  0

; storex: a[p] = X (low two nibbles)
storex: LDM  0
        DCL
        SRC  P0
        LD   R2
        WRM
        LDM  1
        DCL
        SRC  P0
        LD   R3
        WRM
        BBL  0

; dec6: P6 = P6 - 1
dec6:   LD   R13
        DAC
        XCH  R13
        JCN  2, d6x
        LD   R12
        DAC
        XCH  R12
d6x:    BBL  0
