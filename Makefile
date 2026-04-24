AS      = aarch64-linux-gnu-as
LD      = aarch64-linux-gnu-ld
OBJCOPY = aarch64-linux-gnu-objcopy
CC_AARCH64 = aarch64-linux-gnu-gcc

BUILD   = build

# ---------------------------------------------------------------------------
# Platform selection
#   make                      — Pi 3 (QEMU raspi3b, default)
#   make PLATFORM=pi4         — Pi 4 hardware
# ---------------------------------------------------------------------------
PLATFORM_DIR = platform/pi
PLATFORM_ASFLAGS =

ifeq ($(PLATFORM),pi4)
  PLATFORM_ASFLAGS = --defsym PLATFORM_PI4=1
  LINKER_SCRIPT = linker_hw.ld
else
  LINKER_SCRIPT = linker.ld
endif

# ---------------------------------------------------------------------------
# Profile build flag — per-stage cycle-counter instrumentation
#
#   make PLATFORM=pi4 PERF=recv      — probe only genet_recv
#   make PLATFORM=pi4 PERF=send      — probe only genet_send
#   make PLATFORM=pi4 PERF=dispatch  — probe only net_recv_one dispatch
#   make PLATFORM=pi4 PERF=l3        — probe lib/ip.S, lib/icmp.S,
#                                      lib/ip_reasm.S (L3 stage)
#   make PLATFORM=pi4 PERF=all       — probe all stages (highest overhead)
#
# Default (no PERF flag) builds the production kernel with zero
# instrumentation overhead. Use per-stage builds during the grind
# to keep probe overhead small enough that the measurement is
# representative of the default kernel's behavior; use PERF=all
# only for spot-checks or when comparing across stages.
#
# Each stage defines PERF_COUNTERS (umbrella — enables the
# perf_counters struct in lib/perf.S and the macro bodies in
# include/perf.inc) plus a stage-specific flag (PERF_RECV /
# PERF_SEND / PERF_DISPATCH / PERF_L3) that gates the actual probe
# call sites in the hot path. PERF_L3 also enables a second
# 64-byte struct `perf_counters2` in lib/perf.S (L3 cache line).
# ---------------------------------------------------------------------------
PERF_ASFLAGS =
ifeq ($(PERF),recv)
  PERF_ASFLAGS = --defsym PERF_COUNTERS=1 --defsym PERF_RECV=1
else ifeq ($(PERF),send)
  PERF_ASFLAGS = --defsym PERF_COUNTERS=1 --defsym PERF_SEND=1
else ifeq ($(PERF),dispatch)
  PERF_ASFLAGS = --defsym PERF_COUNTERS=1 --defsym PERF_DISPATCH=1
else ifeq ($(PERF),l3)
  PERF_ASFLAGS = --defsym PERF_COUNTERS=1 --defsym PERF_L3=1
else ifeq ($(PERF),all)
  PERF_ASFLAGS = --defsym PERF_COUNTERS=1 --defsym PERF_RECV=1 \
                 --defsym PERF_SEND=1 --defsym PERF_DISPATCH=1 \
                 --defsym PERF_L3=1
else ifneq ($(PERF),)
  $(error Unknown PERF=$(PERF); use recv, send, dispatch, l3, or all)
endif

# ---------------------------------------------------------------------------
# Appliance content / route overrides. Pass CONTENT_MAX=<bytes> (and
# optionally MAX_ROUTES=<n>) to shrink the reserved slab for sites
# smaller than the 256 MiB default — critical for keeping kernel8.img
# small enough to fit on a user's SD card. Both values flow through
# the kernel ELF AND the packager (via HDR_KSIZE cross-check) so the
# two copies stay in lockstep.
#
# Example for a 4 MiB site:
#   make PLATFORM=pi4 CONTENT_MAX=4194304
#   scripts/mk_appliance.py --content-max 4194304 kernel8.img public/ out.img
# Easier: scripts/mk_sd.sh --build public/ sd.img (measures + rebuilds
# + packages + writes the SD image in one step).
# ---------------------------------------------------------------------------
APPLIANCE_OVERRIDE_ASFLAGS =
ifneq ($(CONTENT_MAX),)
  APPLIANCE_OVERRIDE_ASFLAGS += --defsym CONTENT_MAX_OVERRIDE=$(CONTENT_MAX)
endif
ifneq ($(MAX_ROUTES),)
  APPLIANCE_OVERRIDE_ASFLAGS += --defsym MAX_ROUTES_OVERRIDE=$(MAX_ROUTES)
endif

ASFLAGS = -g -I include/ -I $(PLATFORM_DIR)/include/ $(PLATFORM_ASFLAGS) $(PERF_ASFLAGS) $(APPLIANCE_OVERRIDE_ASFLAGS)
LDFLAGS = -T $(LINKER_SCRIPT) -nostdlib

# Shorthand for platform include directories
PI_INC = platform/pi/include

# ---------------------------------------------------------------------------
# Shared library objects (platform-independent)
# ---------------------------------------------------------------------------
SHARED_OBJS = \
    $(BUILD)/vmio_queue.o $(BUILD)/vmio_engine.o \
    $(BUILD)/net_cfg.o $(BUILD)/eth.o $(BUILD)/arp.o \
    $(BUILD)/ip.o $(BUILD)/ip_reasm.o $(BUILD)/icmp.o \
    $(BUILD)/udp.o $(BUILD)/tcp.o $(BUILD)/http.o $(BUILD)/http_parse.o $(BUILD)/http_date.o $(BUILD)/http_chunk.o $(BUILD)/http_status.o $(BUILD)/http_handlers.o \
    $(BUILD)/store.o \
    $(BUILD)/net.o $(BUILD)/timer_hw.o $(BUILD)/timer_pool.o \
    $(BUILD)/ntp.o $(BUILD)/md5.o $(BUILD)/perf.o \
    $(BUILD)/http_output_fsa.o

# ---------------------------------------------------------------------------
# Pi platform objects
# ---------------------------------------------------------------------------
PI_OBJS = \
    $(BUILD)/uart.o $(BUILD)/gpio.o $(BUILD)/mailbox.o \
    $(BUILD)/dwc2.o $(BUILD)/usb_enum.o $(BUILD)/usb_desc.o \
    $(BUILD)/cdc_ecm.o $(BUILD)/usb_bulk.o \
    $(BUILD)/genet.o

PI_TEST_OBJS = \
    $(BUILD)/test_pi_all.o \
    $(BUILD)/test_gpio.o \
    $(BUILD)/test_mailbox.o \
    $(BUILD)/test_dwc2.o $(BUILD)/test_usb_enum.o \
    $(BUILD)/test_usb_fail.o $(BUILD)/test_usb_desc.o \
    $(BUILD)/test_usb_bulk.o $(BUILD)/test_cdc_ecm.o \
    $(BUILD)/test_cdc_ecm_data.o $(BUILD)/test_boot_main.o

# ---------------------------------------------------------------------------
# Select platform objects
# ---------------------------------------------------------------------------
PLAT_OBJS      = $(PI_OBJS)
PLAT_TEST_OBJS = $(PI_TEST_OBJS)
# Pi already has uart.o in PLAT_OBJS
TEST_UART      =

# ---------------------------------------------------------------------------
# Kernel, test, functional-test, and fuzz object lists
# ---------------------------------------------------------------------------
KERNEL_OBJS = $(BUILD)/boot.o $(BUILD)/main.o $(SHARED_OBJS) $(PLAT_OBJS)

SHARED_TEST_OBJS = \
    $(BUILD)/test_main.o $(BUILD)/test_example.o \
    $(BUILD)/test_vmio_queue.o $(BUILD)/test_vmio_engine.o \
    $(BUILD)/test_store.o \
    $(BUILD)/test_eth.o $(BUILD)/test_arp.o \
    $(BUILD)/test_ip.o $(BUILD)/test_icmp.o $(BUILD)/test_udp.o \
    $(BUILD)/test_tcp.o $(BUILD)/test_net.o $(BUILD)/test_timer.o \
    $(BUILD)/test_ntp.o $(BUILD)/test_md5.o $(BUILD)/test_http.o \
    $(BUILD)/test_hex_parse.o $(BUILD)/hex_parse.o \
    $(BUILD)/test_genet_rx_err.o \
    $(BUILD)/test_http_output_fsa.o

TEST_OBJS = $(SHARED_TEST_OBJS) $(PLAT_TEST_OBJS) \
    $(TEST_UART) $(BUILD)/main.o $(SHARED_OBJS) $(PLAT_OBJS)

FUNC_TEST_OBJS = $(BUILD)/test_func_main.o $(BUILD)/test_tcp_func.o \
    $(BUILD)/test_tcp_func_hand.o $(BUILD)/test_reasm_func.o \
    $(BUILD)/test_uart.o $(BUILD)/tcp.o $(BUILD)/ip.o $(BUILD)/ip_reasm.o \
    $(BUILD)/eth.o $(BUILD)/arp.o $(BUILD)/icmp.o $(BUILD)/udp.o \
    $(BUILD)/net_cfg.o $(BUILD)/net.o $(BUILD)/timer_hw.o \
    $(BUILD)/timer_pool.o $(BUILD)/ntp.o $(BUILD)/md5.o $(BUILD)/perf.o

FUZZ_ASM_OBJS = \
    $(BUILD)/net.o $(BUILD)/eth.o $(BUILD)/arp.o $(BUILD)/ip.o \
    $(BUILD)/ip_reasm.o $(BUILD)/icmp.o $(BUILD)/udp.o $(BUILD)/tcp.o \
    $(BUILD)/http.o $(BUILD)/http_parse.o $(BUILD)/http_date.o $(BUILD)/http_chunk.o $(BUILD)/http_status.o $(BUILD)/net_cfg.o $(BUILD)/timer_hw.o \
    $(BUILD)/timer_pool.o $(BUILD)/ntp.o $(BUILD)/md5.o

# ---------------------------------------------------------------------------
# Top-level targets
# ---------------------------------------------------------------------------
.PHONY: all test test-functional fuzz fuzz-corpus fuzz-seq fuzz-corpus-seq chainload clean flash-pi4 verify-fsa-table

all: kernel8.img

kernel8.img: $(BUILD)/kernel8.elf
	$(OBJCOPY) -O binary $< $@

# ---------------------------------------------------------------------------
# verify-fsa-table — cross-check tests/func/http_output_fsa_vectors.tsv
# (the human-authored output-FSA transition-table spec) against the
# compiled http_fsa_trans_table in the kernel ELF. Catches drift
# between the .tsv spec and lib/http_output_fsa.S silently reordering
# cells.
# ---------------------------------------------------------------------------
verify-fsa-table: $(BUILD)/kernel8.elf
	@python3 scripts/verify_fsa_table.py $< tests/func/http_output_fsa_vectors.tsv

$(BUILD)/kernel8.elf: $(KERNEL_OBJS) $(LINKER_SCRIPT)
	$(LD) $(LDFLAGS) $(KERNEL_OBJS) -o $@

# ---------------------------------------------------------------------------
# Test kernel — ALWAYS clean rebuild
#
# Make's timestamp-based dependency logic does NOT detect PLATFORM
# flag changes. If a prior run built with `make PLATFORM=pi4`, every
# .o in build/ was assembled with PLATFORM_PI4=1, and a subsequent
# `make test` would happily reuse those Pi-4-addressed objects to
# link a test kernel that crashes silently on raspi3b QEMU. We have
# been burned by this trap repeatedly — enough that the standing
# rule is: always clean first. The few seconds of a clean rebuild is
# cheap insurance against a class of bugs that look exactly like
# real failures.
#
# Why three recipe lines instead of `test: clean $(BUILD)/...`:
# Make does not guarantee prerequisite evaluation order without
# --serial; declaring `clean` as a prerequisite can let the image
# link race against the clean under `-j`. Calling `$(MAKE) clean`
# and `$(MAKE) build/test_kernel8.img` as sequential recipe lines
# forces strict ordering within this target regardless of -j.
# (Top-level parallelism across unrelated targets is unaffected.)
# ---------------------------------------------------------------------------
test:
	$(MAKE) clean
	$(MAKE) $(BUILD)/test_kernel8.img
	bash scripts/run_tests.sh

$(BUILD)/test_kernel8.img: $(BUILD)/test_kernel8.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/test_kernel8.elf: $(TEST_OBJS) linker.ld
	$(LD) $(LDFLAGS) $(TEST_OBJS) -o $@

# Branch coverage — run tests under QEMU -d in_asm tracing,
# then analyze which conditional branches had both sides executed.
test-coverage:
	$(MAKE) clean
	$(MAKE) $(BUILD)/test_kernel8.img $(BUILD)/test_kernel8.elf
	bash scripts/run_tests_traced.sh
	.venv/bin/python scripts/branch_coverage.py \
		$(BUILD)/test_kernel8.elf $(BUILD)/qemu_trace.log

# Functional test kernel — ALWAYS clean rebuild (see `test` above)
test-functional:
	$(MAKE) clean
	$(MAKE) $(BUILD)/func_kernel8.img
	bash scripts/run_func_tests.sh

# ---------------------------------------------------------------------------
# flash-pi4 — atomic "clean, build for Pi 4, flash" entry point.
#
# The only supported way to get a fresh kernel onto the hardware.
# Running `make PLATFORM=pi4` by hand and then flashing manually is
# fine when you know what you're doing, but this target exists so
# the happy path never forgets `make clean`. Uses the project venv
# so hw_send.py gets the correct pyserial/termios behavior.
#
# The `.venv` guard runs FIRST so a missing venv fails fast, before
# we've wiped build/ with `make clean`. Otherwise a first-time user
# with no venv would lose their existing build artifacts to the
# clean and then hit a cryptic "not found" error.
# ---------------------------------------------------------------------------
flash-pi4:
	@test -x .venv/bin/python || { \
	  echo "flash-pi4: .venv/bin/python not found — create the project venv first"; \
	  echo "  (python3 -m venv .venv && .venv/bin/pip install -r requirements.txt)"; \
	  exit 1; \
	}
	$(MAKE) clean
	$(MAKE) PLATFORM=pi4
	.venv/bin/python scripts/hw_send.py kernel8.img

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

chainload:
	$(MAKE) -C chainload

clean:
	rm -rf $(BUILD) kernel8.img
	$(MAKE) -C chainload clean

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

$(BUILD)/main.o: $(PLATFORM_DIR)/main.S include/perf.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# Shared library objects (lib/)
# ===========================================================================
$(BUILD)/vmio_queue.o: lib/vmio_queue.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/vmio_engine.o: lib/vmio_engine.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/store.o: lib/store.S include/store.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/http_handlers.o: lib/http_handlers.S include/store.inc include/http.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/net_cfg.o: lib/net_cfg.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/eth.o: lib/eth.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/arp.o: lib/arp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/ip.o: lib/ip.S include/net.inc include/perf.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/ip_reasm.o: lib/ip_reasm.S include/net.inc include/timer.inc include/perf.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/icmp.o: lib/icmp.S include/net.inc include/perf.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/udp.o: lib/udp.S include/net.inc include/ntp.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/tcp.o: lib/tcp.S include/tcp.inc include/net.inc include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/http.o: lib/http.S include/http.inc include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/http_parse.o: lib/http_parse.S include/http.inc include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/http_date.o: lib/http_date.S include/http.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/http_chunk.o: lib/http_chunk.S include/http.inc include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/http_status.o: lib/http_status.S include/http.inc include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/http_output_fsa.o: lib/http_output_fsa.S include/http.inc include/tcp.inc include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/net.o: lib/net.S include/net.inc include/perf.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/timer_hw.o: lib/timer_hw.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/timer_pool.o: lib/timer_pool.S include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/ntp.o: lib/ntp.S include/ntp.inc include/net.inc include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/md5.o: lib/md5.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/perf.o: lib/perf.S include/perf.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# Pi platform drivers (platform/pi/)
# ===========================================================================
$(BUILD)/uart.o: platform/pi/drivers/uart.S $(PI_INC)/uart.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/mailbox.o: platform/pi/drivers/mailbox.S $(PI_INC)/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/gpio.o: platform/pi/drivers/gpio.S $(PI_INC)/gpio.inc | $(BUILD)
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

$(BUILD)/genet.o: platform/pi/drivers/genet.S $(PI_INC)/genet.inc $(PI_INC)/mailbox.inc include/perf.inc | $(BUILD)
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

$(BUILD)/test_store.o: tests/test_store.S include/store.inc | $(BUILD)
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

$(BUILD)/test_http.o: tests/test_http.S include/http.inc include/tcp.inc include/net.inc include/store.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_http_output_fsa.o: tests/test_http_output_fsa.S include/http.inc include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_hex_parse.o: tests/test_hex_parse.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_genet_rx_err.o: tests/test_genet_rx_err.S $(PI_INC)/genet.inc include/perf.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/hex_parse.o: chainload/hex_parse.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# ===========================================================================
# Pi platform test objects (tests/pi/)
# ===========================================================================
$(BUILD)/test_pi_all.o: tests/pi/test_pi_all.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_gpio.o: tests/pi/test_gpio.S $(PI_INC)/gpio.inc | $(BUILD)
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

$(BUILD)/reasm_vectors.tsv: tests/func/reasm_func.pict | $(BUILD)
	timeout 120 pict $< /o:max > $@

$(BUILD)/reasm_vectors.bin: $(BUILD)/reasm_vectors.tsv scripts/reasm_oracle.py
	python3 scripts/reasm_oracle.py < $< > $@

$(BUILD)/test_reasm_func.o: tests/test_reasm_func.S $(BUILD)/reasm_vectors.bin include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@
