.PHONY: update-submodules

docs: update-submodules
	cd docs && make html

update-submodules:
	git submodule update --init
