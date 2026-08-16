.PHONY: test build image vmm-artifacts reproducibility-test clean

test:
	go test ./...

build:
	./scripts/build-agent.sh

image:
	./scripts/build-image.sh

vmm-artifacts:
	./scripts/build-vmm-artifacts.sh

reproducibility-test:
	./scripts/test-reproducible-artifacts.sh

clean:
	rm -rf out
