;----------------------------------------------------------;
;	ATTINY84 I2C slave for doing large channel count PWM
;	via daisychained NPIC6C596-Q100 shift registers	
;
;
;	Authors:	Samuel Fink and Ryan Fredette
;----------------------------------------------------------;

.DEVICE	ATTINY84						;Run on the ATTINY 84

;-------------------DEFINE CONSTANTS-----------------------;
.EQU	SLAVE_ADDR		0x43			;define the slave device address. MAXIMUM 7 BITS
.EQU	CHANNEL_COUNT	48				;Define the number of PWM channels to use.	MAXIMUM 1 byte
.EQU	SCL_PIN			0b00010000		;define the bitmask for the SCL pin for recieving I2C clock signal
.EQU	SDA_PIN			0b01000000		;define the bitmask for the SDA pin	for doing I2C data
.EQU	DS_PIN			0b00000001		;define the bitmask for the DS pin for sending data to the shift registers
.EQU	SHCP_PIN		0b00000010		;define the bitmask for the SCHP pin for clocking data into the shift registers
.EQU	STCP_PIN		0b00000100		;define the bitmask for STCP pin for moving shift register values to the output register
.EQU	S_OUT_MASK		0b00000111		;define bitmask for the pins that are used by the shift register
.EQU	STATUS_START	1				;set the enum for the start state of the i2c processing code
.EQU	STATUS_US		2				;set the enum for the reading state of the i2c processing code
.EQU	STATUS_NOTUS	3				;set the enum for the data ignore state of the i2c processing code
.EQU	USI_COUNT_MASK	0b00001111		;define bitmaks for the USI 4 bit counter
.EQU	USIOFI_MASK		0b01000000		;define the bitmask for the USI overflow interupt enable flag	

;-----------------SET REGISTER NAMES-----------------------;
.DEF	BYTE_BUF=R0						;store the current rendering byte in R0
.DEF	BYTE_POS=X						;store the current position of the rendering in R1
.DEF	READ_POS=Y						;store the current byte read in position in R2
.DEF	I2C_STATUS=R3					;store the current i2c status in R3
.DEF	TEMP=R4							;temp register

;--------------------SET UP DATA-----------------------------;
.DSEG									;start data segment
	bytebuff: .BYTE CHANNEL_COUNT		;reserve CHANNEL_COUNT bytes for storing PWM values 

;-----------------START CODE SEGMENT-----------------------;
.CSEG									;begin code segment

setup:
    set		TIM0_OVF	update			;set update to handle timer 0 overflows
    set		USI_OVF		i2c_byte_ready	;set i2c_byte_ready to handle overflow of the bits recieved counter of the USI
    set		USI_STR		i2c_start		;set i2c_start to handle USI start condition 
    set		DDRA		0b10101111		;set the pin directions for port A 
	set		USICR		0b10101000		;USI control enable start interrupt, 2 wire mode, clocked on external pos edge
	;TODO: set clock prescalers for T0 and T1
	;TODO: start timers
	sei									;set the global interrupt enable 
main:									;main wait loop 
	nop									;do nothing
    ijmp		main					;go back to main loop

update:									;callback for overflow of TCNT0
    set		BYTE_POS	bytebuff		;load the start location of the byte buffer into byte_pos	;TODO FIX THIS (fix all mem interactions) to use Words
	addw	BYTE_POS	CHANNEL_COUNT	;shift the pointer to the far end
	add		BYTE_POS	1				;shift the pointer up 1 for begin of loop decrement
loop:									;begin pwm byte processing loop 
    lds		BYTE_BUF	BYTE_POS		;load the current byte of color data from sram
    cbr		PORTA		S_OUT_MASK		;Clear the DS, SHCP, and STCP bits from the output
    cmp		TCNT1H		BYTE_BUF		;compare the current byte value and the Timer1 High byte value
    brsh	nosethigh					;skip setting the data pin if Timer1H >= current byte
    sbr		PORTA		DS_PIN			;else set DS high
nosethigh:
    sbr		PORTA		SHCP_PIN		;set SHCP(clock) high
    dec		BYTE_POS					;set next byte pointer
	cmp		bytebuff	BYTE_POS		;compare the postions of the start of the data and the current byte position
    brne	loop						;if there are still bytes in the array jump to handle next byte
    sbr		PORTA		STCP_PIN		;set STCP(clock) high
    cbr		PORTA		S_OUT_MASK		;Clear the DS, SHCP, and STCP bits from the output
    reti								;return from interrupt     

i2c_start:								;callback for the i2c start interrupt
	set		I2C_STATUS	STATUS_START	;set the status register to started
	cbr		USISR		USI_COUNT_MASK	;clears the USI bitcounter 		
	sbr		USICR		USIOFI_MASK		;set the USI bit counter overflow interrupt enable
	reti								;interrupt return

i2c_byte_ready:							;callback for the USI byte ready interrupt (bit count overflow)
	cei									;disable global interrupts
	cmp		I2C_STATUS	STATUS_START	;check if this is a new I2C packet
	brne	skip_check_addr				;was not an address packet skip checking the addr
	mov		TEMP	USIDR				;copy the data from the I2C register to the temp storage
	lsr		TEMP						;right shift the address packet to remove the R/W bit
	cmp		TEMP	SLAVE_ADDR			;check address against out address
	breq	i2c_was_us					;if it the same handle it
	mov		I2C_STATUS	STATUS_NOT_US	;set the flag that we are not handling this packet
	cbr		USICR		USIOFI_MASK		;dissable the USI counter overflow interrupt so further bytes are ignored
	ijmp	i2c_finish_byte				;done handling the byte GOTO exit byte callback
i2c_was_us:
	mov		I2C_STATUS	STATUS_US		;set the status flag to was us	
	crb		USISR		USI_COUNT_MASK	;clear the USI counter
	sbr		USICR		USIOFI_MASK		;enable counter overflow interrupt
	mov		READ_POS	bytebuff		;set the current read in position to the start of the buffer location
	add		READ_POS	CHANNEL_COUNT	;move the current position to the end of the buffer
	ijmp	i2c_ack						;send ack
skip_check_addr:
	cmp		I2C_STATUS	STATUS_US		;check if we are reading bytes in this packet
	brne	i2c_finish_byte				;we are not reading this packed, note: this jump should never occur
	sts		READ_POS	USIDR			;copy the data from the USI data register to (bytebuff)SRAM
	dec		READ_POS					;decrement the next byte read location  
	mov		TEMP		READ_POS		;copy the current read position to TEMP
	ADD		TEMP		
i2c_ack:
	mov		TEMP		PINA			;copy the data direction register into temp
	sbr		TEMP		SCL_PIN			;clear the clock pin from the temp
	cmp		TEMP		PINA			;check if the SCL pin was set
	breq	ack_SCL_high				;The SCL was high
ack_SCL_low:
	sbr		DDRA		SDA_PIN			;bring SDA high for ack signal	
	ijmp	i2c_ack						;loop until the clock goes high
ack_SCL_high:
	nop									;slight delay for propogation of pin value on bus
	cbr		DDRA		SDA_PIN			;bring SDA low for ending ack signal				
i2c_finish_byte:
	clr		USIDR						;clear the USI data register
	sei									;re-enable global interrupts
	reti								;interrupt return

;i2c_int1:
;    set count 48
;    cmp sda, id
;    jnz notus
;    set us 1
;    jmp ret
;notus:
;    set us 0
;ret:
;    set i2c_irq, i2c_int2
;    reti ; return from interrupt
;
;
;i2c_int2:
;    cmp us, 0
;    jz nowrite
;    write [temp - count], sda
;nowrite:
;    dec count
;    jnz ret
;    # force SCL low
;    copy outbuf, temp
;    # stop forcing SCL low
;    set i2c_irq i2c_int1
;ret:
;    reti ; return from interrupt

; vim:noet ts=4 sw=4 sts=4 ai:
