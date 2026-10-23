;=======================================================================
; e4004.asm  -  compute e = 2.71828182... on the Intel 4004
;
; Target : Intel 4004 SPICE model (gen_i4004_pmos.py) / 4004.com analyzer
; Clock  : 740 kHz, t_CY = 1.35 us -> 1 instruction cycle = 10.8 us
; Result : e to 8 decimal places (2.71828182), BCD, one digit per nibble
;
; METHOD
;   Horner form of the series e = sum 1/k!, k = 0..11:
;       x = 1
;       for k = 11 down to 2:   x = 1 + x / k
;       e = 1 + x
;   x always lies in [1, 2), so its integer digit is always 1 and only the
;   fraction digits f1..f10 are stored (index registers R2..R11).
;
;   x / k is decimal long division, one digit at a time:
;       v = rem*10 + f_i ;  f_i = v / k ;  rem = v mod k
;   That step is done by a lookup table with FIN. ROM page k (address
;   k*256) holds the table for divisor k: the byte at k*256 + rem*16 + d
;   is (new rem)*16 + quotient. FIN P0 uses R0 = rem, R1 = d as the
;   address and puts the new rem back in R0 and the quotient in R1, so one
;   digit costs 5 instruction cycles (LD, XCH, XCH, FIN). Starting the
;   division with rem = 1 divides the integer part 1 as well, and the
;   "+1" afterwards is implicit because the integer part is never stored.
;
;   Each pass only touches the digits it needs: a truncation error in the
;   pass for k is later divided by (k-1)!, so early passes are short.
;   Digits per pass: k=11:4, k=10:5, k=9:6, k=8:7, k=7:8, k=6:8, k=5:9, k=4:10, k=3:10, k=2:10
;   Worst-case total error < 3e-9, so the first 8 decimals are exact.
;   The last 2 stored digits are guard digits and are not reported.
;
; OUTPUT (ROM chip 0 / RAM bank 0, chip 0, register 0)
;   RAM output port (WMP) : 0 = running, 1 = done
;   RAM reg 0 characters  : char 0 = 2, chars 1..8 = decimals (e = 2.71828182)
;   ROM port 0 (WRR)      : the same digits, written one at a time in order
;   The program ends in a one-instruction loop at label HALT.
;
; ROM MAP
;   page 0  (0x000)          start-up, result output, HALT
;   page k  (0x200-0xB00)    division table for k (rows 0..k-1) + pass k code
;   Page 1 is unused, so that page number = divisor.
;
; REGISTERS
;   P0 (R0:R1) rem : digit (FIN address and result)
;   R2..R11    fraction digits f1..f10
;   P7 (R14:R15) SRC address for output
;
; 4004 notes: FIN reads from the page holding the FIN instruction, so each
; pass runs on its own table's page. No FIN sits at a page's last byte.
; JCN condition codes are not used.
;=======================================================================

        ORG 0x000
START:
        LDM 0
        DCL                    ; select RAM bank 0
        FIM P7, 0x00           ; ROM chip 0 / RAM chip 0, reg 0, char 0
        SRC P7
        LDM 0
        WMP                    ; RAM port = 0 (running)
        FIM P1, 0x00           ; x = 1.0000000000 (clear f1..f10)
        FIM P2, 0x00
        FIM P3, 0x00
        FIM P4, 0x00
        FIM P5, 0x00
        JUN DIV11              ; first pass: k = 11

; --- all passes done: e = 1 + x = 2.f1 f2 f3 ...
OUTPUT:
        FIM P7, 0x00           ; RAM char 0, ROM port 0
        SRC P7
        LDM 2                  ; integer digit: 1 + int(x) = 1 + 1
        WRM
        WRR
        INC R15                ; char 1
        SRC P7
        LD R2                  ; f1
        WRM
        WRR
        INC R15                ; char 2
        SRC P7
        LD R3                  ; f2
        WRM
        WRR
        INC R15                ; char 3
        SRC P7
        LD R4                  ; f3
        WRM
        WRR
        INC R15                ; char 4
        SRC P7
        LD R5                  ; f4
        WRM
        WRR
        INC R15                ; char 5
        SRC P7
        LD R6                  ; f5
        WRM
        WRR
        INC R15                ; char 6
        SRC P7
        LD R7                  ; f6
        WRM
        WRR
        INC R15                ; char 7
        SRC P7
        LD R8                  ; f7
        WRM
        WRR
        INC R15                ; char 8
        SRC P7
        LD R9                  ; f8
        WRM
        WRR
        LDM 1
        WMP                    ; RAM port = 1 (done)
HALT:                       ; result ready; gen_i4004_pmos.py stops here
        JUN HALT

;======================================================================
; PAGE 11: x = 1 + x/11   (4 digits)
;======================================================================
        ORG 0xB00
; table: byte rem*16 + d = (rem*10+d mod 11)*16 + (rem*10+d)/11
        DB 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0xA0, 0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x91, 0xA1, 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
        DB 0x82, 0x92, 0xA2, 0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 3
        DB 0x73, 0x83, 0x93, 0xA3, 0x04, 0x14, 0x24, 0x34, 0x44, 0x54, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 4
        DB 0x64, 0x74, 0x84, 0x94, 0xA4, 0x05, 0x15, 0x25, 0x35, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 5
        DB 0x55, 0x65, 0x75, 0x85, 0x95, 0xA5, 0x06, 0x16, 0x26, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 6
        DB 0x46, 0x56, 0x66, 0x76, 0x86, 0x96, 0xA6, 0x07, 0x17, 0x27, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 7
        DB 0x37, 0x47, 0x57, 0x67, 0x77, 0x87, 0x97, 0xA7, 0x08, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 8
        DB 0x28, 0x38, 0x48, 0x58, 0x68, 0x78, 0x88, 0x98, 0xA8, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 9
        DB 0x19, 0x29, 0x39, 0x49, 0x59, 0x69, 0x79, 0x89, 0x99, 0xA9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 10
DIV11:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R1
        XCH R5                 ; store new f4
        JUN DIV10

;======================================================================
; PAGE 10: x = 1 + x/10   (5 digits)
;======================================================================
        ORG 0xA00
; table: byte rem*16 + d = (rem*10+d mod 10)*16 + (rem*10+d)/10
        DB 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71, 0x81, 0x91, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x82, 0x92, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
        DB 0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73, 0x83, 0x93, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 3
        DB 0x04, 0x14, 0x24, 0x34, 0x44, 0x54, 0x64, 0x74, 0x84, 0x94, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 4
        DB 0x05, 0x15, 0x25, 0x35, 0x45, 0x55, 0x65, 0x75, 0x85, 0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 5
        DB 0x06, 0x16, 0x26, 0x36, 0x46, 0x56, 0x66, 0x76, 0x86, 0x96, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 6
        DB 0x07, 0x17, 0x27, 0x37, 0x47, 0x57, 0x67, 0x77, 0x87, 0x97, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 7
        DB 0x08, 0x18, 0x28, 0x38, 0x48, 0x58, 0x68, 0x78, 0x88, 0x98, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 8
        DB 0x09, 0x19, 0x29, 0x39, 0x49, 0x59, 0x69, 0x79, 0x89, 0x99, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 9
DIV10:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R1
        XCH R6                 ; store new f5
        JUN DIV9

;======================================================================
; PAGE 9: x = 1 + x/9   (6 digits)
;======================================================================
        ORG 0x900
; table: byte rem*16 + d = (rem*10+d mod 9)*16 + (rem*10+d)/9
        DB 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71, 0x81, 0x02, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x82, 0x03, 0x13, 0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
        DB 0x33, 0x43, 0x53, 0x63, 0x73, 0x83, 0x04, 0x14, 0x24, 0x34, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 3
        DB 0x44, 0x54, 0x64, 0x74, 0x84, 0x05, 0x15, 0x25, 0x35, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 4
        DB 0x55, 0x65, 0x75, 0x85, 0x06, 0x16, 0x26, 0x36, 0x46, 0x56, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 5
        DB 0x66, 0x76, 0x86, 0x07, 0x17, 0x27, 0x37, 0x47, 0x57, 0x67, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 6
        DB 0x77, 0x87, 0x08, 0x18, 0x28, 0x38, 0x48, 0x58, 0x68, 0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 7
        DB 0x88, 0x09, 0x19, 0x29, 0x39, 0x49, 0x59, 0x69, 0x79, 0x89, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 8
DIV9:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R7
        XCH R1                 ; R1 = f6, A = new f5
        XCH R6                 ; store new f5
        FIN P0
        LD R1
        XCH R7                 ; store new f6
        JUN DIV8

;======================================================================
; PAGE 8: x = 1 + x/8   (7 digits)
;======================================================================
        ORG 0x800
; table: byte rem*16 + d = (rem*10+d mod 8)*16 + (rem*10+d)/8
        DB 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x01, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x21, 0x31, 0x41, 0x51, 0x61, 0x71, 0x02, 0x12, 0x22, 0x32, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x42, 0x52, 0x62, 0x72, 0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
        DB 0x63, 0x73, 0x04, 0x14, 0x24, 0x34, 0x44, 0x54, 0x64, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 3
        DB 0x05, 0x15, 0x25, 0x35, 0x45, 0x55, 0x65, 0x75, 0x06, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 4
        DB 0x26, 0x36, 0x46, 0x56, 0x66, 0x76, 0x07, 0x17, 0x27, 0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 5
        DB 0x47, 0x57, 0x67, 0x77, 0x08, 0x18, 0x28, 0x38, 0x48, 0x58, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 6
        DB 0x68, 0x78, 0x09, 0x19, 0x29, 0x39, 0x49, 0x59, 0x69, 0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 7
DIV8:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R7
        XCH R1                 ; R1 = f6, A = new f5
        XCH R6                 ; store new f5
        FIN P0
        LD R8
        XCH R1                 ; R1 = f7, A = new f6
        XCH R7                 ; store new f6
        FIN P0
        LD R1
        XCH R8                 ; store new f7
        JUN DIV7

;======================================================================
; PAGE 7: x = 1 + x/7   (8 digits)
;======================================================================
        ORG 0x700
; table: byte rem*16 + d = (rem*10+d mod 7)*16 + (rem*10+d)/7
        DB 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x01, 0x11, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x31, 0x41, 0x51, 0x61, 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x62, 0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
        DB 0x24, 0x34, 0x44, 0x54, 0x64, 0x05, 0x15, 0x25, 0x35, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 3
        DB 0x55, 0x65, 0x06, 0x16, 0x26, 0x36, 0x46, 0x56, 0x66, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 4
        DB 0x17, 0x27, 0x37, 0x47, 0x57, 0x67, 0x08, 0x18, 0x28, 0x38, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 5
        DB 0x48, 0x58, 0x68, 0x09, 0x19, 0x29, 0x39, 0x49, 0x59, 0x69, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 6
DIV7:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R7
        XCH R1                 ; R1 = f6, A = new f5
        XCH R6                 ; store new f5
        FIN P0
        LD R8
        XCH R1                 ; R1 = f7, A = new f6
        XCH R7                 ; store new f6
        FIN P0
        LD R9
        XCH R1                 ; R1 = f8, A = new f7
        XCH R8                 ; store new f7
        FIN P0
        LD R1
        XCH R9                 ; store new f8
        JUN DIV6

;======================================================================
; PAGE 6: x = 1 + x/6   (8 digits)
;======================================================================
        ORG 0x600
; table: byte rem*16 + d = (rem*10+d mod 6)*16 + (rem*10+d)/6
        DB 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x01, 0x11, 0x21, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x41, 0x51, 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x03, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x23, 0x33, 0x43, 0x53, 0x04, 0x14, 0x24, 0x34, 0x44, 0x54, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
        DB 0x05, 0x15, 0x25, 0x35, 0x45, 0x55, 0x06, 0x16, 0x26, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 3
        DB 0x46, 0x56, 0x07, 0x17, 0x27, 0x37, 0x47, 0x57, 0x08, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 4
        DB 0x28, 0x38, 0x48, 0x58, 0x09, 0x19, 0x29, 0x39, 0x49, 0x59, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 5
DIV6:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R7
        XCH R1                 ; R1 = f6, A = new f5
        XCH R6                 ; store new f5
        FIN P0
        LD R8
        XCH R1                 ; R1 = f7, A = new f6
        XCH R7                 ; store new f6
        FIN P0
        LD R9
        XCH R1                 ; R1 = f8, A = new f7
        XCH R8                 ; store new f7
        FIN P0
        LD R1
        XCH R9                 ; store new f8
        JUN DIV5

;======================================================================
; PAGE 5: x = 1 + x/5   (9 digits)
;======================================================================
        ORG 0x500
; table: byte rem*16 + d = (rem*10+d mod 5)*16 + (rem*10+d)/5
        DB 0x00, 0x10, 0x20, 0x30, 0x40, 0x01, 0x11, 0x21, 0x31, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x02, 0x12, 0x22, 0x32, 0x42, 0x03, 0x13, 0x23, 0x33, 0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x04, 0x14, 0x24, 0x34, 0x44, 0x05, 0x15, 0x25, 0x35, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
        DB 0x06, 0x16, 0x26, 0x36, 0x46, 0x07, 0x17, 0x27, 0x37, 0x47, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 3
        DB 0x08, 0x18, 0x28, 0x38, 0x48, 0x09, 0x19, 0x29, 0x39, 0x49, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 4
DIV5:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R7
        XCH R1                 ; R1 = f6, A = new f5
        XCH R6                 ; store new f5
        FIN P0
        LD R8
        XCH R1                 ; R1 = f7, A = new f6
        XCH R7                 ; store new f6
        FIN P0
        LD R9
        XCH R1                 ; R1 = f8, A = new f7
        XCH R8                 ; store new f7
        FIN P0
        LD R10
        XCH R1                 ; R1 = f9, A = new f8
        XCH R9                 ; store new f8
        FIN P0
        LD R1
        XCH R10                ; store new f9
        JUN DIV4

;======================================================================
; PAGE 4: x = 1 + x/4   (10 digits)
;======================================================================
        ORG 0x400
; table: byte rem*16 + d = (rem*10+d mod 4)*16 + (rem*10+d)/4
        DB 0x00, 0x10, 0x20, 0x30, 0x01, 0x11, 0x21, 0x31, 0x02, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x22, 0x32, 0x03, 0x13, 0x23, 0x33, 0x04, 0x14, 0x24, 0x34, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x05, 0x15, 0x25, 0x35, 0x06, 0x16, 0x26, 0x36, 0x07, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
        DB 0x27, 0x37, 0x08, 0x18, 0x28, 0x38, 0x09, 0x19, 0x29, 0x39, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 3
DIV4:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R7
        XCH R1                 ; R1 = f6, A = new f5
        XCH R6                 ; store new f5
        FIN P0
        LD R8
        XCH R1                 ; R1 = f7, A = new f6
        XCH R7                 ; store new f6
        FIN P0
        LD R9
        XCH R1                 ; R1 = f8, A = new f7
        XCH R8                 ; store new f7
        FIN P0
        LD R10
        XCH R1                 ; R1 = f9, A = new f8
        XCH R9                 ; store new f8
        FIN P0
        LD R11
        XCH R1                 ; R1 = f10, A = new f9
        XCH R10                ; store new f9
        FIN P0
        LD R1
        XCH R11                ; store new f10
        JUN DIV3

;======================================================================
; PAGE 3: x = 1 + x/3   (10 digits)
;======================================================================
        ORG 0x300
; table: byte rem*16 + d = (rem*10+d mod 3)*16 + (rem*10+d)/3
        DB 0x00, 0x10, 0x20, 0x01, 0x11, 0x21, 0x02, 0x12, 0x22, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x13, 0x23, 0x04, 0x14, 0x24, 0x05, 0x15, 0x25, 0x06, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
        DB 0x26, 0x07, 0x17, 0x27, 0x08, 0x18, 0x28, 0x09, 0x19, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 2
DIV3:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R7
        XCH R1                 ; R1 = f6, A = new f5
        XCH R6                 ; store new f5
        FIN P0
        LD R8
        XCH R1                 ; R1 = f7, A = new f6
        XCH R7                 ; store new f6
        FIN P0
        LD R9
        XCH R1                 ; R1 = f8, A = new f7
        XCH R8                 ; store new f7
        FIN P0
        LD R10
        XCH R1                 ; R1 = f9, A = new f8
        XCH R9                 ; store new f8
        FIN P0
        LD R11
        XCH R1                 ; R1 = f10, A = new f9
        XCH R10                ; store new f9
        FIN P0
        LD R1
        XCH R11                ; store new f10
        JUN DIV2

;======================================================================
; PAGE 2: x = 1 + x/2   (10 digits)
;======================================================================
        ORG 0x200
; table: byte rem*16 + d = (rem*10+d mod 2)*16 + (rem*10+d)/2
        DB 0x00, 0x10, 0x01, 0x11, 0x02, 0x12, 0x03, 0x13, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 0
        DB 0x05, 0x15, 0x06, 0x16, 0x07, 0x17, 0x08, 0x18, 0x09, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; rem 1
DIV2:
        LDM 1
        XCH R0                 ; rem = integer part of x (1)
        LD R2
        XCH R1                 ; R1 = f1
        FIN P0                 ; R0 = rem, R1 = f1 / k
        LD R3
        XCH R1                 ; R1 = f2, A = new f1
        XCH R2                 ; store new f1
        FIN P0
        LD R4
        XCH R1                 ; R1 = f3, A = new f2
        XCH R3                 ; store new f2
        FIN P0
        LD R5
        XCH R1                 ; R1 = f4, A = new f3
        XCH R4                 ; store new f3
        FIN P0
        LD R6
        XCH R1                 ; R1 = f5, A = new f4
        XCH R5                 ; store new f4
        FIN P0
        LD R7
        XCH R1                 ; R1 = f6, A = new f5
        XCH R6                 ; store new f5
        FIN P0
        LD R8
        XCH R1                 ; R1 = f7, A = new f6
        XCH R7                 ; store new f6
        FIN P0
        LD R9
        XCH R1                 ; R1 = f8, A = new f7
        XCH R8                 ; store new f7
        FIN P0
        LD R10
        XCH R1                 ; R1 = f9, A = new f8
        XCH R9                 ; store new f8
        FIN P0
        LD R11
        XCH R1                 ; R1 = f10, A = new f9
        XCH R10                ; store new f9
        FIN P0
        LD R1
        XCH R11                ; store new f10
        JUN OUTPUT

        END
