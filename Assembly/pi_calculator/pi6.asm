; =====================================================================
;  PI6.ASM  --  Intel 4004: compute pi to 6 decimal places
;              3.141592
;  Cut-down version of PI20.ASM sized for transistor-level SPICE runs.
; ---------------------------------------------------------------------
;  Algorithm: Rabinowitz-Wagon decimal spigot.
;     a[i] = 2 for i = 1..L          (L = 31 = 10*9/3 + 1 terms)
;     repeat 9 times:
;        q = 0
;        for i = L downto 1:
;           x    = 10*a[i] + q*i
;           d    = 2i-1   (d = 10 when i = 1)
;           a[i] = x mod d
;           q    = x div d
;        emit q                   (q may be 10 -> carry fixed up later)
;  9 digits are computed and 7 are printed (3 + 6 decimals); the 2
;  extra are guard digits so a pending carry can't corrupt digit 6.
;
;  4004-specific tricks (same as PI20)
;   * x div d by repeated subtraction; 10*a by ten additions.
;   * q*i never multiplied: each subtraction of d at index i adds (i-1)
;     to C, so C = q*(i-1) when the loop ends -- the next carry term.
;   * Subtraction is ADD of -d (ND, two's complement), carry = no borrow.
;     ND starts at -61 and steps by +2 as i falls.
;   * a[i] is 8 bits: low nibble in RAM bank 0, high nibble in bank 1,
;     both at address i-1, which is also the value added to C.
;
;  Largest intermediate values: x < 1024, C < 512 (12-bit regs are ample)
;
;  Register map
;   P0 = R0:R1     p = i-1 = RAM address of a[i]
;   R2 R3 R4       X  working value (low, mid, high nibble)
;   R5 R6 R7       ND = -d, 12-bit two's complement
;   R8 R9 R10      C  = accumulated carry term q*(i-1)
;   R11            loop counter / final quotient (digit)
;   P6 = R12:R13   digit pointer (bank 0, 0x30..0x38)
;   R14 R15        a[i] low / high nibble, scratch
;
;  Memory -- only TWO 4002 RAM chips are touched:
;   CM-RAM0 chip 0:  regs 0-1 = a[] low nibbles, reg 3 = the 9 digits
;   CM-RAM1 chip 0:  regs 0-1 = a[] high nibbles
;  Output: the 7 digits are written in order to ROM chip 0, port 0 (WRR).
; =====================================================================

        ORG 0

; ---- initialise a[0..31] = 2 (lo=2, hi=0) ----------------------------
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
        INC  R0
        LD   R0
        RAR                 ; R0 = 1 -> CY=1 continue, R0 = 2 -> stop
        JCN  2, fill

        FIM  P6, 0x30       ; first digit goes to bank0[0x30]

; ---- one pass of the spigot = one digit -------------------------------
digit:  FIM  P0, 30         ; p = 30  ->  i = 31
        LDM  3              ; ND = -61 = 0xFC3
        XCH  R5
        LDM  12
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
        CLC                 ; ND = ND + 2
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
        LDM  0              ; bank0[ptr] = digit (0..10)
        DCL
        SRC  P6
        LD   R11
        WRM
        INC  R13            ; ptr++ ; stop after 9 digits (R13 = 9)
        CLC
        LDM  7
        ADD  R13            ; A = 0 only when R13 = 9
        JCN  4, fixup
        JUN  digit

; ---- carry fix-up: any digit of 10 becomes 0 and carries left --------
fixup:  FIM  P6, 0x38
        LDM  0
        DCL
fix:    SRC  P6
        RDM
        XCH  R14
        CLC
        LDM  6
        ADD  R14            ; carry iff digit >= 10, A = digit-10
        JCN  10, nofix
        WRM                 ; digit = digit - 10
        LD   R13            ; ptr--
        DAC
        XCH  R13
        SRC  P6
        RDM
        IAC                 ; previous digit + 1
        WRM
        JUN  fixchk
nofix:  LD   R13            ; ptr--
        DAC
        XCH  R13
fixchk: LD   R13            ; stop when ptr reaches 0x30
        JCN  12, fix

; ---- output 7 digits (bank0 0x30..0x36) to ROM port 0 ----------------
        FIM  P6, 0x30
        FIM  P7, 0x00
out:    LDM  0
        DCL
        SRC  P6
        RDM
        SRC  P7             ; select ROM chip 0
        WRR                 ; port 0 <- digit
        INC  R13
        CLC
        LDM  9
        ADD  R13            ; A = 0 only when R13 = 7
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
