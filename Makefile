.PHONY: help setup test tasks workers doctor
help:
	@python3 sagequeue.py --help
setup:
	bin/setup.sh
test:
	python3 -m unittest discover -s tests -v
tasks:
	python3 sagequeue.py tasks
workers:
	python3 sagequeue.py workers
doctor:
	python3 sagequeue.py doctor
