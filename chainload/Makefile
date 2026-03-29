AS      = aarch64-linux-gnu-as
LD      = aarch64-linux-gnu-ld
OBJCOPY = aarch64-linux-gnu-objcopy

ASFLAGS = --fatal-warnings -I ../platform/pi/include/
OBJS    = boot.o hex_parse.o

all: chainload.img

chainload.img: chainload.elf
	$(OBJCOPY) -O binary $< $@

chainload.elf: $(OBJS) chainload.ld
	$(LD) -T chainload.ld -nostdlib $(OBJS) -o $@

%.o: %.S
	$(AS) $(ASFLAGS) $< -o $@

clean:
	rm -f *.o *.elf *.img
