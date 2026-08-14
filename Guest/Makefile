.PHONY: test build image vmm-artifacts clean

test:
	go test ./...

build:
	./scripts/build-agent.sh

image:
	./scripts/build-image.sh

vmm-artifacts:
	./scripts/build-vmm-artifacts.sh

clean:
	rm -rf out
