ZIG_VERSION := 0.10.0-dev.3051+b8bf5de75
IMAGE_NAME := zigci
ZIG_TARGET := x86_64-macos.12
TRIPETS := x86_64-macos.12 aarch64-macos.12 x86_64-linux

clean:
	$(RM) -rf zig-cache zig-out
	$(foreach TRIPET,$(TRIPETS), $(RM) -rf $(TRIPET);)

test:
	zig build test

fmt:
	find . -name "*.zig" -exec zig fmt --check {} \;

release:
	$(foreach TRIPLET,$(TRIPETS),make build ZIG_TARGET=$(TRIPLET);)
	$(foreach TRIPLET,$(TRIPETS),mv $(TRIPLET)/bin/kontext kontext-$(TRIPLET);)

build:
	zig build -Drelease-safe=true -Dtarget=$(ZIG_TARGET) -p $(ZIG_TARGET)

docker-build:
	docker build \
		-t $(IMAGE_NAME) \
		--build-arg ZIG_VERSION=$(ZIG_VERSION) \
		-f Dockerfile .

docker-%: docker-build
	docker run \
		--rm \
		--privileged \
		-v $(shell pwd):/data \
		-w /data $(DOCKER_EXTRA_ARGS) \
		$(IMAGE_NAME) sh -c "make $*"
