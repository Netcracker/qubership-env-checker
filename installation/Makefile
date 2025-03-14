APP_NAME=jupyter-all

# grep the version from the mix file
VERSION=$(shell ./version.sh)

# HELP
# This will output the help for each task
# thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.PHONY: help
help: ## This help.
    @awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help

# DOCKER TASKS
# Build the container
build: ## Build the container
    docker build -t $(APP_NAME) .

build-nc: ## Build the container without caching
    docker build --no-cache -t $(APP_NAME) .

release: build-nc publish ## Make a release by building and publishing the `{version}` and `latest` tagged containers to ECR

# Docker tagging
tag: tag-latest tag-version ## Generate container tags for the `{version}` and `latest` tags

tag-latest: ## Generate container `{version}` tag
    @echo 'create tag latest'
    docker tag $(APP_NAME) $(APP_NAME):latest

tag-version: ## Generate container `latest` tag
    @echo 'create tag $(VERSION)'
    docker tag $(APP_NAME) $(APP_NAME):$(VERSION)

version: ## Output the current version
    @echo $(VERSION)

clean: ## clean go smm-service
    $(MAKE) -C smm-service clean

build-all: build-smm-service build tag publish ## build all
