AS      = aarch64-linux-gnu-as
LD      = aarch64-linux-gnu-ld
OBJCOPY = aarch64-linux-gnu-objcopy

all: kernel8.img

kernel8.img: uart_test.elf
	$(OBJCOPY) -O binary $< $@

uart_test.elf: boot.o uart_test.ld
	$(LD) -T uart_test.ld -nostdlib $< -o $@

boot.o: boot.S
	$(AS) $< -o $@

clean:
	rm -f *.o *.elf *.img
