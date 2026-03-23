AS      = aarch64-linux-gnu-as
LD      = aarch64-linux-gnu-ld
OBJCOPY = aarch64-linux-gnu-objcopy
CC_AARCH64 = aarch64-linux-gnu-gcc

BUILD   = build

# ---------------------------------------------------------------------------
# Platform selection
#   make                      — Pi 3 (QEMU raspi3b, default)
#   make PLATFORM=pi4         — Pi 4 hardware
#   make PLATFORM=beagleplay  — BeaglePlay (AM625)
# ---------------------------------------------------------------------------
PLATFORM_DIR = platform/pi
PLATFORM_TAG = pi
PLATFORM_ASFLAGS =

ifeq ($(PLATFORM),pi4)
  PLATFORM_DIR = platform/pi
  PLATFORM_TAG = pi
  PLATFORM_ASFLAGS = --defsym PLATFORM_PI4=1
else ifeq ($(PLATFORM),beagleplay)
  PLATFORM_DIR = platform/beagleplay
  PLATFORM_TAG = beagleplay
endif

ASFLAGS = -I include/ -I $(PLATFORM_DIR)/include/ $(PLATFORM_ASFLAGS)
LDFLAGS = -T linker.ld -nostdlib

# Shorthand for platform include directories
PI_INC = platform/pi/include
BP_INC = platform/beagleplay/include

# ---------------------------------------------------------------------------
# Shared library objects (platform-independent)
# ---------------------------------------------------------------------------
SHARED_OBJS = \
    $(BUILD)/vmio_queue.o $(BUILD)/vmio_engine.o \
    $(BUILD)/net_cfg.o $(BUILD)/eth.o $(BUILD)/arp.o \
    $(BUILD)/ip.o $(BUILD)/ip_reasm.o $(BUILD)/icmp.o \
    $(BUILD)/udp.o $(BUILD)/tcp.o $(BUILD)/http.o \
    $(BUILD)/net.o $(BUILD)/timer_hw.o $(BUILD)/timer_pool.o \
    $(BUILD)/ntp.o $(BUILD)/md5.o

# ---------------------------------------------------------------------------
# Pi platform objects
# ---------------------------------------------------------------------------
PI_OBJS = \
    $(BUILD)/uart.o $(BUILD)/mailbox.o \
    $(BUILD)/dwc2.o $(BUILD)/usb_enum.o $(BUILD)/usb_desc.o \
    $(BUILD)/cdc_ecm.o $(BUILD)/usb_bulk.o

PI_TEST_OBJS = \
    $(BUILD)/test_pi_all.o \
    $(BUILD)/test_mailbox.o \
    $(BUILD)/test_dwc2.o $(BUILD)/test_usb_enum.o \
    $(BUILD)/test_usb_fail.o $(BUILD)/test_usb_desc.o \
    $(BUILD)/test_usb_bulk.o $(BUILD)/test_cdc_ecm.o \
    $(BUILD)/test_cdc_ecm_data.o $(BUILD)/test_boot_main.o

# ---------------------------------------------------------------------------
# BeaglePlay platform objects
# ---------------------------------------------------------------------------
BP_OBJS = \
    $(BUILD)/cpsw_mdio.o \
    $(BUILD)/cpsw_port.o

BP_TEST_OBJS = \
    $(BUILD)/test_bp_all.o \
    $(BUILD)/test_cpsw_mdio.o \
    $(BUILD)/test_cpsw_port.o

# ---------------------------------------------------------------------------
# Select platform objects
# ---------------------------------------------------------------------------
ifeq ($(PLATFORM_TAG),beagleplay)
  PLAT_OBJS      = $(BP_OBJS)
  PLAT_TEST_OBJS = $(BP_TEST_OBJS)
  # Non-Pi platforms need Pi UART for test output (QEMU raspi3b)
  TEST_UART      = $(BUILD)/test_uart.o
else
  PLAT_OBJS      = $(PI_OBJS)
  PLAT_TEST_OBJS = $(PI_TEST_OBJS)
  # Pi already has uart.o in PLAT_OBJS
  TEST_UART      =
endif

# ---------------------------------------------------------------------------
# Kernel, test, functional-test, and fuzz object lists
# ---------------------------------------------------------------------------
KERNEL_OBJS = $(BUILD)/boot.o $(BUILD)/main.o $(SHARED_OBJS) $(PLAT_OBJS)

SHARED_TEST_OBJS = \
    $(BUILD)/test_main.o $(BUILD)/test_example.o \
    $(BUILD)/test_vmio_queue.o $(BUILD)/test_vmio_engine.o \
    $(BUILD)/test_eth.o $(BUILD)/test_arp.o \
    $(BUILD)/test_ip.o $(BUILD)/test_icmp.o $(BUILD)/test_udp.o \
    $(BUILD)/test_tcp.o $(BUILD)/test_net.o $(BUILD)/test_timer.o \
    $(BUILD)/test_ntp.o $(BUILD)/test_md5.o $(BUILD)/test_http.o

TEST_OBJS = $(SHARED_TEST_OBJS) $(PLAT_TEST_OBJS) \
    $(TEST_UART) $(BUILD)/main.o $(SHARED_OBJS) $(PLAT_OBJS)

FUNC_TEST_OBJS = $(BUILD)/test_func_main.o $(BUILD)/test_tcp_func.o \
    $(BUILD)/test_tcp_func_hand.o \
    $(BUILD)/uart.o $(BUILD)/tcp.o $(BUILD)/ip.o $(BUILD)/ip_reasm.o \
    $(BUILD)/eth.o $(BUILD)/arp.o $(BUILD)/icmp.o $(BUILD)/udp.o \
    $(BUILD)/net_cfg.o $(BUILD)/net.o $(BUILD)/timer_hw.o \
    $(BUILD)/timer_pool.o $(BUILD)/ntp.o $(BUILD)/md5.o

FUZZ_ASM_OBJS = \
    $(BUILD)/net.o $(BUILD)/eth.o $(BUILD)/arp.o $(BUILD)/ip.o \
    $(BUILD)/ip_reasm.o $(BUILD)/icmp.o $(BUILD)/udp.o $(BUILD)/tcp.o \
    $(BUILD)/http.o $(BUILD)/net_cfg.o $(BUILD)/timer_hw.o \
    $(BUILD)/timer_pool.o $(BUILD)/ntp.o $(BUILD)/md5.o

# ---------------------------------------------------------------------------
# Top-level targets
# ---------------------------------------------------------------------------
.PHONY: all test test-functional fuzz fuzz-corpus fuzz-seq fuzz-corpus-seq clean

all: kernel8.img

kernel8.img: $(BUILD)/kernel8.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/kernel8.elf: $(KERNEL_OBJS) linker.ld
	$(LD) $(LDFLAGS) $(KERNEL_OBJS) -o $@

# Test kernel
test: $(BUILD)/test_kernel8.img scripts/run_tests.sh
	bash scripts/run_tests.sh

$(BUILD)/test_kernel8.img: $(BUILD)/test_kernel8.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/test_kernel8.elf: $(TEST_OBJS) linker.ld
	$(LD) $(LDFLAGS) $(TEST_OBJS) -o $@

# Functional test kernel
test-functional: $(BUILD)/func_kernel8.img scripts/run_func_tests.sh
	bash scripts/run_func_tests.sh

$(BUILD)/func_kernel8.img: $(BUILD)/func_kernel8.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/func_kernel8.elf: $(FUNC_TEST_OBJS) linker.ld
	$(LD) $(LDFLAGS) $(FUNC_TEST_OBJS) -o $@

# Fuzz harnesses
fuzz: $(BUILD)/fuzz_net

$(BUILD)/fuzz_net.o: fuzz/fuzz_net.c | $(BUILD)
	$(CC_AARCH64) -c -O2 -o $@ $<

$(BUILD)/fuzz_net: $(BUILD)/fuzz_net.o $(FUZZ_ASM_OBJS)
	$(CC_AARCH64) -static -o $@ $^

fuzz-corpus: fuzz/gen_corpus.py
	python3 fuzz/gen_corpus.py

fuzz-seq: $(BUILD)/fuzz_tcp_seq

$(BUILD)/fuzz_tcp_seq.o: fuzz/fuzz_tcp_seq.c | $(BUILD)
	$(CC_AARCH64) -c -O2 -o $@ $<

$(BUILD)/fuzz_tcp_seq: $(BUILD)/fuzz_tcp_seq.o $(FUZZ_ASM_OBJS)
	$(CC_AARCH64) -static -o $@ $^

fuzz-corpus-seq: fuzz/gen_corpus_seq.py
	python3 fuzz/gen_corpus_seq.py

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) kernel8.img

# ===========================================================================
# Test UART — always Pi PL011 (test kernel runs on QEMU raspi3b)
# ===========================================================================
$(BUILD)/test_uart.o: platform/pi/drivers/uart.S $(PI_INC)/uart.inc | $(BUILD)
	$(AS) -I include/ -I $(PI_INC)/ $< -o $@

# ===========================================================================
# Platform boot + main (selected by PLATFORM_DIR)
# ===========================================================================
$(BUILD)/boot.o: $(PLATFORM_DIR)/boot.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/main.o: $(PLATFORM_DIR)/main.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# Shared library objects (lib/)
# ===========================================================================
$(BUILD)/vmio_queue.o: lib/vmio_queue.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/vmio_engine.o: lib/vmio_engine.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/net_cfg.o: lib/net_cfg.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/eth.o: lib/eth.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/arp.o: lib/arp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/ip.o: lib/ip.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/ip_reasm.o: lib/ip_reasm.S include/net.inc include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/icmp.o: lib/icmp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/udp.o: lib/udp.S include/net.inc include/ntp.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/tcp.o: lib/tcp.S include/tcp.inc include/net.inc include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/http.o: lib/http.S include/http.inc include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/net.o: lib/net.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/timer_hw.o: lib/timer_hw.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/timer_pool.o: lib/timer_pool.S include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/ntp.o: lib/ntp.S include/ntp.inc include/net.inc include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/md5.o: lib/md5.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# Pi platform drivers (platform/pi/)
# ===========================================================================
$(BUILD)/uart.o: platform/pi/drivers/uart.S $(PI_INC)/uart.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/mailbox.o: platform/pi/drivers/mailbox.S $(PI_INC)/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/dwc2.o: platform/pi/drivers/dwc2.S $(PI_INC)/dwc2.inc $(PI_INC)/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_enum.o: platform/pi/drivers/usb_enum.S $(PI_INC)/dwc2.inc $(PI_INC)/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_desc.o: platform/pi/drivers/usb_desc.S $(PI_INC)/dwc2.inc $(PI_INC)/usb.inc $(PI_INC)/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/cdc_ecm.o: platform/pi/drivers/cdc_ecm.S $(PI_INC)/dwc2.inc $(PI_INC)/usb.inc $(PI_INC)/usb_desc.inc $(PI_INC)/cdc_ecm.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_bulk.o: platform/pi/drivers/usb_bulk.S $(PI_INC)/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# BeaglePlay platform drivers (platform/beagleplay/)
# ===========================================================================
$(BUILD)/cpsw_mdio.o: platform/beagleplay/drivers/cpsw_mdio.S $(BP_INC)/cpsw.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/cpsw_port.o: platform/beagleplay/drivers/cpsw_port.S $(BP_INC)/cpsw.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# Shared test objects (tests/)
# ===========================================================================
$(BUILD)/test_main.o: tests/test_main.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_example.o: tests/test_example.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_vmio_queue.o: tests/test_vmio_queue.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_vmio_engine.o: tests/test_vmio_engine.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_eth.o: tests/test_eth.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_arp.o: tests/test_arp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_ip.o: tests/test_ip.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_icmp.o: tests/test_icmp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_udp.o: tests/test_udp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_tcp.o: tests/test_tcp.S include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_net.o: tests/test_net.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_timer.o: tests/test_timer.S include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_ntp.o: tests/test_ntp.S include/ntp.inc include/net.inc include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_md5.o: tests/test_md5.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_http.o: tests/test_http.S include/http.inc include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# Pi platform test objects (tests/pi/)
# ===========================================================================
$(BUILD)/test_pi_all.o: tests/pi/test_pi_all.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_mailbox.o: tests/pi/test_mailbox.S $(PI_INC)/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_dwc2.o: tests/pi/test_dwc2.S $(PI_INC)/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_enum.o: tests/pi/test_usb_enum.S $(PI_INC)/dwc2.inc $(PI_INC)/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_fail.o: tests/pi/test_usb_fail.S $(PI_INC)/dwc2.inc $(PI_INC)/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_desc.o: tests/pi/test_usb_desc.S $(PI_INC)/dwc2.inc $(PI_INC)/usb.inc $(PI_INC)/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_bulk.o: tests/pi/test_usb_bulk.S $(PI_INC)/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_cdc_ecm.o: tests/pi/test_cdc_ecm.S $(PI_INC)/dwc2.inc $(PI_INC)/usb.inc $(PI_INC)/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_cdc_ecm_data.o: tests/pi/test_cdc_ecm_data.S $(PI_INC)/dwc2.inc $(PI_INC)/cdc_ecm.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_boot_main.o: tests/pi/test_boot_main.S $(PI_INC)/dwc2.inc $(PI_INC)/usb.inc $(PI_INC)/usb_desc.inc $(PI_INC)/cdc_ecm.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# BeaglePlay platform test objects (tests/beagleplay/)
# ===========================================================================
$(BUILD)/test_bp_all.o: tests/beagleplay/test_bp_all.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_cpsw_mdio.o: tests/beagleplay/test_cpsw_mdio.S $(BP_INC)/cpsw.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_cpsw_port.o: tests/beagleplay/test_cpsw_port.S $(BP_INC)/cpsw.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# Functional test objects
# ===========================================================================
$(BUILD)/tcp_vectors.tsv: tests/func/tcp_func.pict | $(BUILD)
	timeout 120 pict $< /o:max > $@

$(BUILD)/tcp_vectors.bin: $(BUILD)/tcp_vectors.tsv scripts/tcp_oracle.py
	python3 scripts/tcp_oracle.py < $< > $@

$(BUILD)/test_func_main.o: tests/test_func_main.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_tcp_func.o: tests/test_tcp_func.S $(BUILD)/tcp_vectors.bin include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_tcp_func_hand.o: tests/test_tcp_func_hand.S include/tcp.inc include/net.inc include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@
