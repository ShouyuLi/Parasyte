APP := migi
DIST_DIR := dist

.PHONY: build release-build clean

build:
	go build -o bin/$(APP) ./cmd/migi

release-build:
	mkdir -p $(DIST_DIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o $(DIST_DIR)/$(APP)-linux-amd64 ./cmd/migi
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o $(DIST_DIR)/$(APP)-linux-arm64 ./cmd/migi
	cd $(DIST_DIR) && LC_ALL=C LANG=C shasum -a 256 $(APP)-linux-* > checksums.txt

clean:
	rm -rf bin $(DIST_DIR)
