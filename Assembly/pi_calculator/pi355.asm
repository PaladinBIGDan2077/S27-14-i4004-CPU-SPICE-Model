; =====================================================================
;  PI355.ASM  --  Intel 4004: pi to 6 decimal places in ~1,300 cycles
;                 355 / 113 = 3.14159292...  ->  prints 3141592
; ---------------------------------------------------------------------
;  Zu Chongzhi's fraction 355/113 matches pi to 6 decimal places
;  (pi = 3.14159265..., error 2.7e-7).  Digits come from plain long
;  division:  first digit = 355 div 113, then  R = 10*R, digit = R div 113.
;
;  Needs one 4001 ROM and nothing else: no 4002 RAM is used.
;
;  Register map
;   R2 R3 R4    X  = running remainder (low, mid, high nibble), 12 bit
;   R5 R6 R7    ND = -113 = 0xF8F (two's complement; ADD ND = subtract)
;   R8 R9 R10   T  = scratch copy of 2*X for the multiply by 10
;   R11         quotient digit
;   R12         digit counter (ISZ from 9 -> 16 = 7 digits)
;   P7          ROM chip select for WRR (chip 0)
;  Output: 7 digits, in order, on ROM chip 0 I/O port 0.
; =====================================================================

        ORG 0

start:  FIM  P1, 0x36       ; X = 355 = 0x163  (R2 = 3, R3 = 6)
        LDM  1
        XCH  R4
        LDM  15             ; ND = -113 = 0xF8F
        XCH  R5
        LDM  8
        XCH  R6
        LDM  15
        XCH  R7
        FIM  P7, 0x00       ; select ROM chip 0 for WRR
        SRC  P7
        LDM  9              ; 7 digits
        XCH  R12
        JUN  divide         ; first digit: 355 div 113, no x10

; ---- X = 10*X  (2X, keep it, 8X, add) --------------------------------
next:   CLC                 ; X = 2X
        LD   R2
        ADD  R2
        XCH  R2
        LD   R3
        ADD  R3
        XCH  R3
        LD   R4
        ADD  R4
        XCH  R4
        LD   R2             ; T = 2X
        XCH  R8
        LD   R3
        XCH  R9
        LD   R4
        XCH  R10
        CLC                 ; X = 4X
        LD   R2
        ADD  R2
        XCH  R2
        LD   R3
        ADD  R3
        XCH  R3
        LD   R4
        ADD  R4
        XCH  R4
        CLC                 ; X = 8X
        LD   R2
        ADD  R2
        XCH  R2
        LD   R3
        ADD  R3
        XCH  R3
        LD   R4
        ADD  R4
        XCH  R4
        CLC                 ; X = 8X + 2X = 10X
        LD   R2
        ADD  R8
        XCH  R2
        LD   R3
        ADD  R9
        XCH  R3
        LD   R4
        ADD  R10
        XCH  R4

; ---- digit = X div 113, X = X mod 113 --------------------------------
divide: LDM  0
        XCH  R11
dloop:  CLC                 ; trial: X + ND carries  <=>  X >= 113
        LD   R2
        ADD  R5
        LD   R3
        ADD  R6
        LD   R4
        ADD  R7
        JCN  10, ddone      ; no carry -> X < 113
        CLC                 ; X = X - 113
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
        JUN  dloop
ddone:  LD   R11
        WRR                 ; port 0 <- digit
        ISZ  R12, next
halt:   JUN  halt
