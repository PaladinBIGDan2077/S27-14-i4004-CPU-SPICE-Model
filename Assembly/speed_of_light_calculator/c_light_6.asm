; =====================================================================
; c_light.asm  --  Speed of light to 6 significant digits on the Intel 4004
;
; Method:  c = f * lambda  (iodine-stabilised He-Ne 633 nm reference line,
;          CIPM recommended values, truncated to 6 digits each)
;             f      = 473.612 THz      (multiplier)
;             lambda = 632.991 nm       (multiplicand)
;          THz * nm = 1e12 * 1e-9 = 1e3 m/s, so
;             c = 473612 * 632991 * 1e-3  m/s  = 299 792 133 xxx  -> 2.99792e8 m/s
;
; Algorithm: 6x6-digit packed-BCD long multiplication by repeated, shifted
;   addition. The 12-digit product lives in index registers R11(MS)..R0(LS).
;   For each multiplier digit d at decimal position k, the multiplicand is
;   added d times into R(k)..R(k+5) (ADD + DAA per digit), with any decimal
;   carry rippled into the higher digits only while a carry is pending.
;   R12 = repeat counter (ISZ, preloaded with 16-d).  P7 (R14,R15) = SRC address.
;
; Output when done:
;   * R11..R6 hold the six digits 2 9 9 7 9 2 (R5..R0 hold the remainder)
;   * 4002 RAM chip0/reg0 characters 0..5 = 2,9,9,7,9,2   (WRM)
;   * ROM I/O port 0 is driven with each digit in turn, MS first (WRR)
;   * CPU then parks in a tight JUN loop at label DONE.
;
; Timing (740 kHz clock, 10.8 us per 1-word instr, 21.6 us per 2-word):
;   see header in the accompanying report -- 793 (8.56 ms) instruction cycles.
; =====================================================================

        ORG  0x000
START:  CLB                      ; A=0, carry=0
        ; ---- clear product registers R0..R11 ----
        FIM  P0, 0x00
        FIM  P1, 0x00
        FIM  P2, 0x00
        FIM  P3, 0x00
        FIM  P4, 0x00
        FIM  P5, 0x00

; ---- multiplier digit 2 at 10^0: add 632991 x2 into R5..R0 ----
        LDM  14
        XCH  R12                 ; counter = 16-2
ADD0:   CLC
        LDM  1
        ADD  R0
        DAA
        XCH  R0
        LDM  9
        ADD  R1
        DAA
        XCH  R1
        LDM  9
        ADD  R2
        DAA
        XCH  R2
        LDM  2
        ADD  R3
        DAA
        XCH  R3
        LDM  3
        ADD  R4
        DAA
        XCH  R4
        LDM  6
        ADD  R5
        DAA
        XCH  R5
        JCN  0xA, NC0          ; carry=0 -> no further ripple
        LDM  0
        ADD  R6
        DAA
        XCH  R6
        JCN  0xA, NC0          ; carry=0 -> no further ripple
        LDM  0
        ADD  R7
        DAA
        XCH  R7
        JCN  0xA, NC0          ; carry=0 -> no further ripple
        LDM  0
        ADD  R8
        DAA
        XCH  R8
        JCN  0xA, NC0          ; carry=0 -> no further ripple
        LDM  0
        ADD  R9
        DAA
        XCH  R9
        JCN  0xA, NC0          ; carry=0 -> no further ripple
        LDM  0
        ADD  R10
        DAA
        XCH  R10
        JCN  0xA, NC0          ; carry=0 -> no further ripple
        LDM  0
        ADD  R11
        DAA
        XCH  R11
NC0:    ISZ  R12, ADD0

; ---- multiplier digit 1 at 10^1: add 632991 x1 into R6..R1 ----
        LDM  15
        XCH  R12                 ; counter = 16-1
ADD1:   CLC
        LDM  1
        ADD  R1
        DAA
        XCH  R1
        LDM  9
        ADD  R2
        DAA
        XCH  R2
        LDM  9
        ADD  R3
        DAA
        XCH  R3
        LDM  2
        ADD  R4
        DAA
        XCH  R4
        LDM  3
        ADD  R5
        DAA
        XCH  R5
        LDM  6
        ADD  R6
        DAA
        XCH  R6
        JCN  0xA, NC1          ; carry=0 -> no further ripple
        LDM  0
        ADD  R7
        DAA
        XCH  R7
        JCN  0xA, NC1          ; carry=0 -> no further ripple
        LDM  0
        ADD  R8
        DAA
        XCH  R8
        JCN  0xA, NC1          ; carry=0 -> no further ripple
        LDM  0
        ADD  R9
        DAA
        XCH  R9
        JCN  0xA, NC1          ; carry=0 -> no further ripple
        LDM  0
        ADD  R10
        DAA
        XCH  R10
        JCN  0xA, NC1          ; carry=0 -> no further ripple
        LDM  0
        ADD  R11
        DAA
        XCH  R11
NC1:    ISZ  R12, ADD1

; ---- multiplier digit 6 at 10^2: add 632991 x6 into R7..R2 ----
        LDM  10
        XCH  R12                 ; counter = 16-6
ADD2:   CLC
        LDM  1
        ADD  R2
        DAA
        XCH  R2
        LDM  9
        ADD  R3
        DAA
        XCH  R3
        LDM  9
        ADD  R4
        DAA
        XCH  R4
        LDM  2
        ADD  R5
        DAA
        XCH  R5
        LDM  3
        ADD  R6
        DAA
        XCH  R6
        LDM  6
        ADD  R7
        DAA
        XCH  R7
        JCN  0xA, NC2          ; carry=0 -> no further ripple
        LDM  0
        ADD  R8
        DAA
        XCH  R8
        JCN  0xA, NC2          ; carry=0 -> no further ripple
        LDM  0
        ADD  R9
        DAA
        XCH  R9
        JCN  0xA, NC2          ; carry=0 -> no further ripple
        LDM  0
        ADD  R10
        DAA
        XCH  R10
        JCN  0xA, NC2          ; carry=0 -> no further ripple
        LDM  0
        ADD  R11
        DAA
        XCH  R11
NC2:    ISZ  R12, ADD2

        PAGE                     ; JUN to next page; loop stays inside one ROM page
; ---- multiplier digit 3 at 10^3: add 632991 x3 into R8..R3 ----
        LDM  13
        XCH  R12                 ; counter = 16-3
ADD3:   CLC
        LDM  1
        ADD  R3
        DAA
        XCH  R3
        LDM  9
        ADD  R4
        DAA
        XCH  R4
        LDM  9
        ADD  R5
        DAA
        XCH  R5
        LDM  2
        ADD  R6
        DAA
        XCH  R6
        LDM  3
        ADD  R7
        DAA
        XCH  R7
        LDM  6
        ADD  R8
        DAA
        XCH  R8
        JCN  0xA, NC3          ; carry=0 -> no further ripple
        LDM  0
        ADD  R9
        DAA
        XCH  R9
        JCN  0xA, NC3          ; carry=0 -> no further ripple
        LDM  0
        ADD  R10
        DAA
        XCH  R10
        JCN  0xA, NC3          ; carry=0 -> no further ripple
        LDM  0
        ADD  R11
        DAA
        XCH  R11
NC3:    ISZ  R12, ADD3

; ---- multiplier digit 7 at 10^4: add 632991 x7 into R9..R4 ----
        LDM  9
        XCH  R12                 ; counter = 16-7
ADD4:   CLC
        LDM  1
        ADD  R4
        DAA
        XCH  R4
        LDM  9
        ADD  R5
        DAA
        XCH  R5
        LDM  9
        ADD  R6
        DAA
        XCH  R6
        LDM  2
        ADD  R7
        DAA
        XCH  R7
        LDM  3
        ADD  R8
        DAA
        XCH  R8
        LDM  6
        ADD  R9
        DAA
        XCH  R9
        JCN  0xA, NC4          ; carry=0 -> no further ripple
        LDM  0
        ADD  R10
        DAA
        XCH  R10
        JCN  0xA, NC4          ; carry=0 -> no further ripple
        LDM  0
        ADD  R11
        DAA
        XCH  R11
NC4:    ISZ  R12, ADD4

; ---- multiplier digit 4 at 10^5: add 632991 x4 into R10..R5 ----
        LDM  12
        XCH  R12                 ; counter = 16-4
ADD5:   CLC
        LDM  1
        ADD  R5
        DAA
        XCH  R5
        LDM  9
        ADD  R6
        DAA
        XCH  R6
        LDM  9
        ADD  R7
        DAA
        XCH  R7
        LDM  2
        ADD  R8
        DAA
        XCH  R8
        LDM  3
        ADD  R9
        DAA
        XCH  R9
        LDM  6
        ADD  R10
        DAA
        XCH  R10
        JCN  0xA, NC5          ; carry=0 -> no further ripple
        LDM  0
        ADD  R11
        DAA
        XCH  R11
NC5:    ISZ  R12, ADD5

; ---- publish the six significant digits (R11..R6) ----
        FIM  P7, 0x00            ; RAM chip0 reg0 char0 / ROM port 0
        SRC  P7
        LD   R11
        WRM                      ; RAM char
        WRR                      ; ROM port 0
        INC  R15
        SRC  P7
        LD   R10
        WRM                      ; RAM char
        WRR                      ; ROM port 0
        INC  R15
        SRC  P7
        LD   R9
        WRM                      ; RAM char
        WRR                      ; ROM port 0
        INC  R15
        SRC  P7
        LD   R8
        WRM                      ; RAM char
        WRR                      ; ROM port 0
        INC  R15
        SRC  P7
        LD   R7
        WRM                      ; RAM char
        WRR                      ; ROM port 0
        INC  R15
        SRC  P7
        LD   R6
        WRM                      ; RAM char
        WRR                      ; ROM port 0
DONE:   JUN  DONE
        END
