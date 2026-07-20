# Verification entrypoint for the Concierge engine.
# `make verify` is what CI runs.

.PHONY: verify install test lint

verify: install lint test

install:
	bundle install --quiet

lint:
	bin/rubocop

test:
	bin/test
