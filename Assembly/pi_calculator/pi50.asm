; =====================================================================
;  PI50.ASM  --  Intel 4004: compute pi to 50 decimal places
;   3.14159265358979323846264338327950288419716939937510
; ---------------------------------------------------------------------
;  Algorithm: Rabinowitz-Wagon decimal spigot (same as PI20.ASM).
;     a[i] = 2 for i = 1..L          (L = 181 = 10*54/3 + 1 terms)
;     repeat 54 times:
;        q = 0
;        for i = L downto 1:
;           x    = 10*a[i] + q*i
;           d    = 2i-1   (d = 10 when i = 1)
;           a[i] = x mod d
;           q    = x div d
;        emit q                   (q may be 10 -> carry fixed up later)
;  54 digits are computed and 51 are printed (3 + 50 decimals); the
;  extra 3 are guard digits so pending carries can't corrupt digit 50.
;
;  Width changes vs. PI20 (bounds checked in Python):
;     a[i] <= 358   -> 3 nibbles per entry (RAM banks 0, 1, 2)
;     x    <= 6324  -> X is 16 bits (R2 R3 R4 R12)
;     C    <= 3006  -> 12 bits is still enough (R8 R9 R10)
;     d    <= 361   -> ND = -d is 16 bits; its top nibble is always F,
;                      so it is supplied with LDM 15 instead of a register
;  The digit pointer no longer fits in registers, so it lives in RAM.
;
;  Same 4004 tricks as PI20
;   * x div d by repeated subtraction (q <= 18); 10*a by ten additions.
;   * q*i never multiplied: each subtraction of d at index i adds (i-1)
;     to C, so C = q*(i-1) when the loop ends -- the next carry term.
;   * Subtraction = ADD of -d (ND), so carry means "no borrow".
;     ND starts at -361 and steps by +2 as i falls.
;   * P0 holds p = i-1: both the RAM address of a[i] and the C increment.
;
;  Register map
;   P0 = R0:R1     p = i-1 = RAM address of a[i]
;   R2 R3 R4 R12   X  working value, 16 bits (low .. high nibble)
;   R5 R6 R7       ND = -d, low 12 bits (top nibble implied F)
;   R8 R9 R10      C  = accumulated carry term q*(i-1)
;   R11            loop counter / final quotient (digit)
;   R13            a[i] high nibble (scratch) ; P6 = digit pointer later
;   R14 R15        a[i] low / mid nibble (scratch) ; P7 = scratch pointer
;
;  Memory (4002 RAM, 10 chips)
;   bank 0 (CM-RAM0) chips 0-2:  a[] low  nibbles, addresses 0x00..0xB4
;   bank 1 (CM-RAM1) chips 0-2:  a[] mid  nibbles
;   bank 2 (CM-RAM2) chips 0-2:  a[] high nibbles
;   bank 0 chip 3:  0xC0..0xF5 = the 54 digits, 0xFE/0xFF = digit pointer
;  Output: the 51 digits are written in order to ROM chip 0, port 0.
; =====================================================================

        ORG 0

; ---- initialise a[0..191] = 2 (lo=2, mid=0, hi=0) --------------------
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
        LDM  2
        DCL
        SRC  P0
        LDM  0
        WRM                 ; bank2[p] = 0
        ISZ  R1, fill
        INC  R0
        CLC
        LDM  4
        ADD  R0             ; A = 0 only when R0 = 12 (p = 0xC0)
        JCN  12, fill

        LDM  0              ; digit pointer = 0xC0
        DCL
        FIM  P7, 0xFE
        SRC  P7
        LDM  12
        WRM
        FIM  P7, 0xFF
        SRC  P7
        LDM  0
        WRM

; ---- one pass of the spigot = one digit -------------------------------
digit:  FIM  P0, 180        ; p = 180  ->  i = 181
        LDM  7              ; ND = -361 = 0xFE97
        XCH  R5
        LDM  9
        XCH  R6
        LDM  14
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
        LDM  15
        ADD  R12
        JCN  10, done       ; no carry -> X < d, X is the remainder
        JMS  subnd          ; X = X - d
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
        LDM  6              ; ND = -10 = 0xFFF6
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
        LDM  15
        ADD  R12
        JCN  10, dn1
        JMS  subnd
        INC  R11
        JUN  dv1
dn1:    JMS  storex         ; a[1] = x mod 10
        JMS  getptr         ; P6 = digit pointer
        SRC  P6             ; bank0[ptr] = digit (0..10)
        LD   R11
        WRM
        ISZ  R13, nc        ; ptr++
        INC  R12
nc:     JMS  putptr
        LD   R12            ; stop at ptr = 0xF6 (54 digits)
        IAC                 ; A = 0 only when R12 = 15
        JCN  12, more
        CLC
        LDM  10
        ADD  R13            ; A = 0 only when R13 = 6
        JCN  4, fixup
more:   JUN  digit

; ---- carry fix-up: any digit of 10 becomes 0 and carries left --------
fixup:  FIM  P6, 0xF5
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
        JMS  dec6
        SRC  P6
        RDM
        IAC                 ; previous digit + 1
        WRM
        JUN  fixchk
nofix:  JMS  dec6
fixchk: LD   R13            ; stop when ptr reaches 0xC0
        JCN  12, fix
        CLC
        LDM  4
        ADD  R12            ; A = 0 only when R12 = 12
        JCN  12, fix

        JUN  output

; ---- output 51 digits (bank0 0xC0..0xF2) to ROM port 0 ---------------
;      (starts ROM page 1 so its short jumps stay inside one page)
        ORG  0x100
output: FIM  P6, 0xC0
        FIM  P7, 0x00
out:    LDM  0
        DCL
        SRC  P6
        RDM
        SRC  P7             ; select ROM chip 0
        WRR                 ; port 0 <- digit
        ISZ  R13, ochk
        INC  R12
ochk:   LD   R12            ; stop at ptr = 0xF3
        IAC
        JCN  12, out
        CLC
        LDM  13
        ADD  R13            ; A = 0 only when R13 = 3
        JCN  12, out
halt:   JUN  halt

; ---- subroutines ------------------------------------------------------
; subnd: X = X + ND  (i.e. X - d), 16 bits
subnd:  CLC
        LD   R2
        ADD  R5
        XCH  R2
        LD   R3
        ADD  R6
        XCH  R3
        LD   R4
        ADD  R7
        XCH  R4
        LDM  15
        ADD  R12
        XCH  R12
        BBL  0

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
        XCH  R15            ; a mid
        LDM  2
        DCL
        SRC  P0
        RDM
        XCH  R13            ; a high
        LD   R8             ; X = C
        XCH  R2
        LD   R9
        XCH  R3
        LD   R10
        XCH  R4
        LDM  0
        XCH  R12
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
        LD   R4
        ADD  R13
        XCH  R4
        LDM  0
        ADD  R12
        XCH  R12
        ISZ  R11, mul
        BBL  0

; storex: a[p] = X (low three nibbles; X < d <= 361 here)
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
        LDM  2
        DCL
        SRC  P0
        LD   R4
        WRM
        BBL  0

; getptr: P6 = digit pointer from bank0[0xFE:0xFF] (leaves bank 0 selected)
getptr: LDM  0
        DCL
        FIM  P7, 0xFE
        SRC  P7
        RDM
        XCH  R12
        FIM  P7, 0xFF
        SRC  P7
        RDM
        XCH  R13
        BBL  0

; putptr: bank0[0xFE:0xFF] = P6
putptr: FIM  P7, 0xFE
        SRC  P7
        LD   R12
        WRM
        FIM  P7, 0xFF
        SRC  P7
        LD   R13
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
