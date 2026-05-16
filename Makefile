# Convenience targets for local ARM64 Linux bring-up.
# Meson remains the source of truth for actual builds; this Makefile captures
# the repeatable build/test flows used during runtime coverage work.

MESON ?= meson
NINJA ?= ninja
CC ?= clang

RELEASE_BUILD_DIR ?= build-arm64-linux
DEBUG_BUILD_DIR ?= build-arm64-linux-debug
ROOTFS_DIR ?= $(CURDIR)/alpine-arm64-fakefs
DEBIAN_ROOTFS_DIR ?= $(CURDIR)/debian-arm64-fakefs
DEBIAN_SUITE ?= trixie
NODE_VERSION ?= 24.14.1
BUN_VERSION ?= 1.3.13
ROOTFS_LANES ?= alpine=$(ROOTFS_DIR) debian=$(DEBIAN_ROOTFS_DIR)
AI_CLI_PACKAGE_MANAGERS ?= npm bun pip
REPORT_DIR ?= /workspace/tmp
TIMEOUT_S ?= 120
INSTALL_TIMEOUT_S ?= 1200

.PHONY: help
help:
	@echo "iSH ARM64 local targets:"
	@echo "  make build-arm64-linux              Build release Linux host binary"
	@echo "  make build-arm64-linux-debug        Build debug Linux host binary"
	@echo "  make build-arm64-linux-all          Build release + debug"
	@echo "  make test-arm64-runtime-coverage    Run staged C/Go/Bun/Node/Python/Lua/Java/Clojure/PyPy/Swift/Rust/Erlang/Zig coverage"
	@echo "  make test-arm64-runtime-coverage-debug"
	@echo "                                      Run coverage against debug binary"
	@echo "  make test-arm64-internal-continue-fixtures"
	@echo "                                      Run opt-in ARM64 internal-continue first-call-site fixtures"
	@echo "  make debian-arm64-fakefs           Build minimal Debian ARM64 fakefs lane"
	@echo "  make test-arm64-ai-cli-runtime-coverage"
	@echo "                                      Run second-stage AI CLI npm/Bun/pip install/startup coverage"
	@echo "  make test-arm64-ai-cli-npm-runtime-coverage"
	@echo "                                      Run npm-only AI CLI coverage across ROOTFS_LANES"
	@echo "  make test-arm64-ai-cli-runtime-coverage-debug"
	@echo "                                      Run AI CLI coverage against debug binary"
	@echo ""
	@echo "Knobs: ROOTFS_DIR=$(ROOTFS_DIR) DEBIAN_ROOTFS_DIR=$(DEBIAN_ROOTFS_DIR) ROOTFS_LANES=$(ROOTFS_LANES) AI_CLI_PACKAGE_MANAGERS=$(AI_CLI_PACKAGE_MANAGERS) REPORT_DIR=$(REPORT_DIR) TIMEOUT_S=$(TIMEOUT_S) INSTALL_TIMEOUT_S=$(INSTALL_TIMEOUT_S)"

.PHONY: build-arm64-linux
build-arm64-linux:
	@test -d "$(RELEASE_BUILD_DIR)" || CC="$(CC)" $(MESON) setup "$(RELEASE_BUILD_DIR)" -Dguest_arch=arm64 --buildtype=release
	$(NINJA) -C "$(RELEASE_BUILD_DIR)"

.PHONY: build-arm64-linux-debug
build-arm64-linux-debug:
	@test -d "$(DEBUG_BUILD_DIR)" || CC="$(CC)" $(MESON) setup "$(DEBUG_BUILD_DIR)" -Dguest_arch=arm64 --buildtype=debug
	$(NINJA) -C "$(DEBUG_BUILD_DIR)"

.PHONY: build-arm64-linux-all
build-arm64-linux-all: build-arm64-linux build-arm64-linux-debug

$(DEBIAN_ROOTFS_DIR): | build-arm64-linux
	@command -v debootstrap >/dev/null || { echo "missing debootstrap; install it first (sudo apt install debootstrap)" >&2; exit 1; }
	@set -eu; \
	WORK="$(REPORT_DIR)/debian-arm64-rootfs"; \
	TAR="$(REPORT_DIR)/debian-arm64-minimal.tar"; \
	sudo rm -rf "$$WORK" "$@"; \
	sudo debootstrap --arch=arm64 --variant=minbase \
	  --include=ca-certificates,curl,wget,busybox,file,tar,gzip,xz-utils,sed,grep,findutils,bash,python3,python3-venv,python3-pip \
	  "$(DEBIAN_SUITE)" "$$WORK" http://deb.debian.org/debian; \
	mkdir -p "$(REPORT_DIR)/node-v$(NODE_VERSION)-linux-arm64" "$(REPORT_DIR)/bun-v$(BUN_VERSION)-linux-aarch64"; \
	cd "$(REPORT_DIR)/node-v$(NODE_VERSION)-linux-arm64"; \
	if [ ! -d node-v$(NODE_VERSION)-linux-arm64 ]; then curl -L --fail -O https://nodejs.org/dist/v$(NODE_VERSION)/node-v$(NODE_VERSION)-linux-arm64.tar.xz; tar -xf node-v$(NODE_VERSION)-linux-arm64.tar.xz; fi; \
	sudo rm -rf "$$WORK/opt/node-v$(NODE_VERSION)-linux-arm64"; \
	sudo cp -a "$(REPORT_DIR)/node-v$(NODE_VERSION)-linux-arm64/node-v$(NODE_VERSION)-linux-arm64" "$$WORK/opt/"; \
	sudo ln -sf /opt/node-v$(NODE_VERSION)-linux-arm64/bin/node "$$WORK/usr/local/bin/node"; \
	sudo ln -sf /opt/node-v$(NODE_VERSION)-linux-arm64/bin/npm "$$WORK/usr/local/bin/npm"; \
	sudo ln -sf /opt/node-v$(NODE_VERSION)-linux-arm64/bin/npx "$$WORK/usr/local/bin/npx"; \
	cd "$(REPORT_DIR)/bun-v$(BUN_VERSION)-linux-aarch64"; \
	if [ ! -d bun-linux-aarch64 ]; then curl -L --fail -o bun-linux-aarch64.zip https://github.com/oven-sh/bun/releases/download/bun-v$(BUN_VERSION)/bun-linux-aarch64.zip; unzip -q bun-linux-aarch64.zip; fi; \
	sudo install -d "$$WORK/usr/local/bin"; \
	sudo install -m 0755 "$(REPORT_DIR)/bun-v$(BUN_VERSION)-linux-aarch64/bun-linux-aarch64/bun" "$$WORK/usr/local/bin/bun"; \
	printf 'nameserver 1.1.1.1\n' | sudo tee "$$WORK/etc/resolv.conf" >/dev/null; \
	printf 'deb http://deb.debian.org/debian $(DEBIAN_SUITE) main\n' | sudo tee "$$WORK/etc/apt/sources.list" >/dev/null; \
	sudo chroot "$$WORK" /bin/sh -lc 'apt-get clean; rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/lintian /usr/share/linda'; \
	sudo tar --numeric-owner -C "$$WORK" -cf "$$TAR" .; \
	"$(CURDIR)/$(RELEASE_BUILD_DIR)/tools/fakefsify" "$$TAR" "$@"

.PHONY: debian-arm64-fakefs
debian-arm64-fakefs: $(DEBIAN_ROOTFS_DIR)

.PHONY: test-arm64-runtime-coverage
test-arm64-runtime-coverage: build-arm64-linux $(DEBIAN_ROOTFS_DIR)
	ISH_BIN="$(CURDIR)/$(RELEASE_BUILD_DIR)/ish" \
	ROOTFS="$(ROOTFS_DIR)" \
	ROOTFS_LANES="$(ROOTFS_LANES)" \
	REPORT_DIR="$(REPORT_DIR)" \
	TIMEOUT_S="$(TIMEOUT_S)" \
	INSTALL_TIMEOUT_S="$(INSTALL_TIMEOUT_S)" \
	./tests/arm64/runtime-coverage.sh

.PHONY: test-arm64-runtime-coverage-debug
test-arm64-runtime-coverage-debug: build-arm64-linux-debug $(DEBIAN_ROOTFS_DIR)
	ISH_BIN="$(CURDIR)/$(DEBUG_BUILD_DIR)/ish" \
	ROOTFS="$(ROOTFS_DIR)" \
	ROOTFS_LANES="$(ROOTFS_LANES)" \
	REPORT_DIR="$(REPORT_DIR)" \
	TIMEOUT_S="$(TIMEOUT_S)" \
	INSTALL_TIMEOUT_S="$(INSTALL_TIMEOUT_S)" \
	./tests/arm64/runtime-coverage.sh

.PHONY: test-arm64-node-bun-perf
test-arm64-node-bun-perf: build-arm64-linux
	ISH_BIN="$(CURDIR)/$(RELEASE_BUILD_DIR)/ish" \
	ROOTFS="$(ROOTFS_DIR)" \
	ROOTFS_LANES="$(ROOTFS_LANES)" \
	REPORT_DIR="$(REPORT_DIR)" \
	TIMEOUT_S="$(TIMEOUT_S)" \
	./tests/arm64/node-bun-perf-table.sh

.PHONY: test-arm64-internal-continue-fixtures
test-arm64-internal-continue-fixtures: build-arm64-linux
	ISH_BIN="$(CURDIR)/$(RELEASE_BUILD_DIR)/ish" \
	ROOTFS="$(ROOTFS_DIR)" \
	REPORT_DIR="$(REPORT_DIR)" \
	TIMEOUT_S="$(TIMEOUT_S)" \
	./tests/arm64/internal-continue-fixtures.sh

.PHONY: test-arm64-ai-cli-runtime-coverage
test-arm64-ai-cli-runtime-coverage: build-arm64-linux $(DEBIAN_ROOTFS_DIR)
	ISH_BIN="$(CURDIR)/$(RELEASE_BUILD_DIR)/ish" \
	ROOTFS="$(ROOTFS_DIR)" \
	ROOTFS_LANES="$(ROOTFS_LANES)" \
	AI_CLI_PACKAGE_MANAGERS="$(AI_CLI_PACKAGE_MANAGERS)" \
	REPORT_DIR="$(REPORT_DIR)" \
	TIMEOUT_S="$(TIMEOUT_S)" \
	INSTALL_TIMEOUT_S="$(INSTALL_TIMEOUT_S)" \
	./tests/arm64/ai-cli-runtime-coverage.sh

.PHONY: test-arm64-ai-cli-npm-runtime-coverage
test-arm64-ai-cli-npm-runtime-coverage: build-arm64-linux $(DEBIAN_ROOTFS_DIR)
	ISH_BIN="$(CURDIR)/$(RELEASE_BUILD_DIR)/ish" \
	ROOTFS="$(ROOTFS_DIR)" \
	ROOTFS_LANES="$(ROOTFS_LANES)" \
	AI_CLI_PACKAGE_MANAGERS="npm" \
	REPORT_DIR="$(REPORT_DIR)" \
	TIMEOUT_S="$(TIMEOUT_S)" \
	INSTALL_TIMEOUT_S="$(INSTALL_TIMEOUT_S)" \
	./tests/arm64/ai-cli-runtime-coverage.sh

.PHONY: test-arm64-ai-cli-runtime-coverage-debug
test-arm64-ai-cli-runtime-coverage-debug: build-arm64-linux-debug $(DEBIAN_ROOTFS_DIR)
	ISH_BIN="$(CURDIR)/$(DEBUG_BUILD_DIR)/ish" \
	ROOTFS="$(ROOTFS_DIR)" \
	ROOTFS_LANES="$(ROOTFS_LANES)" \
	AI_CLI_PACKAGE_MANAGERS="$(AI_CLI_PACKAGE_MANAGERS)" \
	REPORT_DIR="$(REPORT_DIR)" \
	TIMEOUT_S="$(TIMEOUT_S)" \
	INSTALL_TIMEOUT_S="$(INSTALL_TIMEOUT_S)" \
	./tests/arm64/ai-cli-runtime-coverage.sh
