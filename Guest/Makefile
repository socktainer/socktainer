.PHONY: test build image clean

test:
	go test ./...

build:
	./scripts/build-agent.sh

image:
	./scripts/build-image.sh

clean:
	rm -rf out
