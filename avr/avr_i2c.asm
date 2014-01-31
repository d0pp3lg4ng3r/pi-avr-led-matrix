;----------------------------------------------------------;
;   ATTINY84 I2C slave for doing large channel count PWM
;   via daisychained NPIC6C596-Q100 shift registers 
;
;
;   Authors:    Samuel Fink and Ryan Fredette
;----------------------------------------------------------;

.DEVICE  ATtiny84                            ;Run on the ATTINY 84
.INCLUDE "tn84def.inc"

;-------------------DEFINE CONSTANTS-----------------------;
.EQU    SLAVE_ADDR     =0x43                ;define the slave device address. MAXIMUM 7 BITS
.EQU    CHANNEL_COUNT  =48                  ;Define the number of PWM channels to use.  MAXIMUM 1 byte
.EQU    SCL_PIN        =0b00010000          ;define the bitmask for the SCL pin for recieving I2C clock signal
.EQU    SDA_PIN        =0b01000000          ;define the bitmask for the SDA pin for doing I2C data
.EQU    DS_PIN         =0b00000001          ;define the bitmask for the DS pin for sending data to the shift registers
.EQU    SHCP_PIN       =0b00000010          ;define the bitmask for the SCHP pin for clocking data into the shift registers
.EQU    STCP_PIN       =0b00000100          ;define the bitmask for STCP pin for moving shift register values to the output register
.EQU    S_OUT_MASK     =0b00000111          ;define bitmask for the pins that are used by the shift register
.EQU    STATUS_START   =1                   ;set the enum for the start state of the i2c processing code
.EQU    STATUS_US      =2                   ;set the enum for the reading state of the i2c processing code
.EQU    STATUS_NOT_US  =3                   ;set the enum for the data ignore state of the i2c processing code
.EQU    STATUS_DONE    =4                   ;set the enum for we cant store any more data
.EQU    USI_COUNT_MASK =0b00001111          ;define bitmaks for the USI 4 bit counter
.EQU    USIOFI_MASK    =0b01000000          ;define the bitmask for the USI overflow interupt enable flag   

;-----------------SET REGISTER NAMES-----------------------;
.DEF    BYTE_BUF       =R17                  ;store the current rendering byte in R0
.DEF    BYTE_POS       =R18                  ;store the current offset of the rendering in R1
.DEF    READ_POS       =R19                  ;store the current byte read offset in position in R2
.DEF    I2C_STATUS     =R20                  ;store the current i2c status in R3
.DEF    TEMP           =R21                  ;temp register
.DEF    PORTA_VAL      =R22                  ;what the PORTA value uhould be

.CSEG
;--------------------SET INTERRUPTS------------------------;
.ORG    $0000
            rjmp        setup               ;specify entry point
.ORG    OVF1addr
            rjmp        update              ;set update to handle timer 0 overflows
.ORG    USI_OVFaddr
            rjmp        i2c_byte_ready      ;set i2c_byte_ready to handle overflow of the bits recieved counter of the USI
.ORG    USI_STRaddr
            rjmp        i2c_start           ;set i2c_start to handle USI start condition

;---------------------SET UP DATA--------------------------;
.DSEG                                       ;start data segment
    bytebuff: .BYTE CHANNEL_COUNT           ;reserve CHANNEL_COUNT bytes for storing PWM values 

;-----------------START CODE SEGMENT-----------------------;
.CSEG                                       ;begin code segment
.ORG 0x60

setup:                                      ;system entry point
	ldi		TEMP,       $AF
    out     DDRA,       TEMP                ;set the pin directions for port A   (0b10101111)
    ldi     TEMP,       $A8 
	out     USICR,      TEMP                ;USI control enable start interrupt, 2 wire mode, clocked on external pos edge  (0b10101000)
	ldi     TEMP,       $FF
	out     OCR0A,      TEMP                ;Set Timer 0 to count to max value
	ldi     TEMP,       $2
	out     TCCR0A,     TEMP                ;Set waveform mode to CTC mode
	ldi     TEMP,       $4
	out     TCCR0B,     TEMP                ;Set timer 0 prescaler to 256
	ldi     TEMP,       $1
	out     TIMSK0,     TEMP                ;Enable Timer 0 overflow interrupt
	ldi     TEMP,       $14
	out     TCCR1B,     TEMP                ;Set clock prescale to 256 and WGM to CTC mode  (0b00010100)
    sei                                     ;set the global interrupt enable 
main:                                       ;main wait loop 
    nop                                     ;do nothing TODO: replace this with sleep mode
    rjmp    main                            ;go back to main loop

update:                                     ;callback for overflow of TCNT0
    ldi      YH,         high(bytebuff)     ;load the high byte of the address into the pointer
    ldi      YL,         low(bytebuff)      ;load the low byte of the address into the pointer
    adiw     Y,          CHANNEL_COUNT      ;offset the read location start
loop:                                       ;begin pwm byte processing loop 
    ld      BYTE_BUF,    -Y                 ;decrement the pointer and load the current byte of color data from sram
    cbr     PORTA_VAL,   S_OUT_MASK         ;Clear the DS, SHCP, and STCP bits from the output
	out     PORTA,       PORTA_VAL          ;
	in      TEMP,        TCNT1H
    cp      BYTE_BUF,    TEMP               ;compare the current byte value and the Timer1 High byte value
    brlo    nosethigh                       ;skip setting the data pin if Timer1H > current byte
    sbr     PORTA_VAL,   DS_PIN             ;else set DS high
	out     PORTA,       PORTA_VAL
nosethigh:
    sbr     PORTA_VAL,   SHCP_PIN           ;set SHCP(clock) high
	out     PORTA,       PORTA_VAL          ;
    dec     BYTE_POS                        ;set next byte pointer
    tst     BYTE_POS                        ;compare the postions of the start of the data and the current byte position
    brne    loop                            ;if there are still bytes in the array jump to handle next byte
finalize:
    sbr     PORTA_VAL,  STCP_PIN            ;set STCP(clock) high
	out     PORTA,      PORTA_VAL           ;
    cbr     PORTA_VAL,  S_OUT_MASK          ;Clear the DS, SHCP, and STCP bits from the output
	out     PORTA,      PORTA_VAL          ;
    reti                                    ;return from interrupt     

i2c_start:                                  ;callback for the i2c start interrupt
    ldi     I2C_STATUS, STATUS_START        ;set the status register to started
	in      TEMP,       USISR
    cbr     TEMP,       USI_COUNT_MASK      ;clears the USI bitcounter   
	out     USISR,      TEMP
	in      TEMP,       USICR   
    sbr     TEMP,       USIOFI_MASK         ;set the USI bit counter overflow interrupt enable
	out     USICR,      TEMP
    reti                                    ;interrupt return

i2c_byte_ready:                             ;callback for the USI byte ready interrupt (bit count overflow)
    cli                                     ;disable global interrupts
    cpi     I2C_STATUS, STATUS_START        ;check if this is a new I2C packet
    brne    skip_check_addr                 ;was not an address packet skip checking the addr
    in      TEMP,       USIDR               ;copy the data from the I2C register to the temp storage
    lsr     TEMP                            ;right shift the address packet to remove the R/W bit
    cpi     TEMP,       SLAVE_ADDR          ;check address against out address
    breq    i2c_was_us                      ;if it the same handle it
    ldi     I2C_STATUS, STATUS_NOT_US       ;set the flag that we are not handling this packet
	in      TEMP,      USICR
    cbr     TEMP,      USIOFI_MASK         ;dissable the USI counter overflow interrupt so further bytes are ignored
	out     USICR,     TEMP
    rjmp    i2c_finish_byte                 ;done handling the byte GOTO exit byte callback
i2c_was_us:
    ldi     I2C_STATUS, STATUS_US           ;set the status flag to was us  
	in      TEMP,       USISR
    cbr     TEMP,       USI_COUNT_MASK      ;clear the USI counter
	out     USISR,      TEMP
    ldi     READ_POS,   CHANNEL_COUNT       ;reset the current read offset to channel count (1 past end of array)
    ldi     ZH,         high(bytebuff)      ;load the high byte of the address into the pointer
    ldi     ZL,         low(bytebuff)       ;load the low byte of the address into the pointer
    adiw    Z,          CHANNEL_COUNT       ;offset the read location start
	in      TEMP,       USICR
    sbr     TEMP,       USIOFI_MASK         ;enable counter overflow interrupt
	out     USICR,      TEMP
    rjmp    i2c_ack                         ;send ack
skip_check_addr:
    cpi     I2C_STATUS, STATUS_US           ;check if we are reading bytes in this packet
    brne    i2c_finish_byte                 ;we are not reading this packed, note: this jump should never occur
	in      TEMP,       USIDR
    st      -Z,         TEMP                ;decrement Z and copy the data from the USI data register to the adddress in Z
    dec     READ_POS                        ;decrement the next byte read location  
    tst     READ_POS                        ;check if out of bytes we can store
    brne    i2c_ack                         ;we can read more so move to ack
    ldi     I2C_STATUS, STATUS_DONE         ;we cant read any more so set status to out of space        
i2c_ack:
    in      TEMP,       PINA                ;copy the data direction register into temp
    sbr     TEMP,       SCL_PIN             ;clear the clock pin from the temp
    in      TEMP,       PINA                ;check if the SCL pin was set
    breq    ack_SCL_high                    ;The SCL was high
ack_SCL_low:
    in      TEMP,       DDRA
    sbr     TEMP,       SDA_PIN             ;bring SDA high for ack signal
	out     DDRA,       TEMP  
    rjmp    i2c_ack                         ;loop until the clock goes high
ack_SCL_high:
    nop                                     ;slight delay for propogation of pin value on bus
	in      TEMP,       DDRA
    cbr     TEMP,       SDA_PIN             ;bring SDA low for ending ack signal      
	out     DDRA,       TEMP          
i2c_finish_byte:
    clr     TEMP                            
	out     USIDR,      TEMP                ;clear the USI data register
    sei                                     ;re-enable global interrupts
    reti                                    ;interrupt return

; vim:et ts=4 sw=4 sts=4 ai:
