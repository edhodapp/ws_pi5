AS      = aarch64-linux-gnu-as
LD      = aarch64-linux-gnu-ld
OBJCOPY = aarch64-linux-gnu-objcopy

ASFLAGS = -I ../platform/pi/include/

all: chainload.img

chainload.img: chainload.elf
	$(OBJCOPY) -O binary $< $@

chainload.elf: boot.o chainload.ld
	$(LD) -T chainload.ld -nostdlib $< -o $@

boot.o: boot.S
	$(AS) $(ASFLAGS) $< -o $@

clean:
	rm -f *.o *.elf *.img
