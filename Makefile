# =============================================================================
# usque в Docker — шпаргалка по командам: make help
# =============================================================================
IMAGE    ?= usque:local
REGISTRY ?=
REF      ?= main
ARCHES   ?= linux/amd64,linux/arm64,linux/arm/v7
TESTCFG  ?= /tmp/usque-test-config
HUB_USER ?=
HUB_REPO ?= usque
TAG      ?= latest

# при указании REGISTRY мультиарх-образ пушится в него, иначе грузится локально
BUILDX_OUT = $(if $(REGISTRY),--push,--load)
IMAGE_TAG  = $(if $(REGISTRY),$(REGISTRY):$(TAG),$(IMAGE))

.DEFAULT_GOAL := help

## help: список команд
help:
	@echo "usque в Docker:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'

## build: собрать образ для текущей архитектуры
build:
	docker build --build-arg USQUE_REF=$(REF) -t $(IMAGE) .

## buildx: мультиарх-сборка (нужен binfmt для чужой арх.); с REGISTRY — пуш в реестр
buildx:
	docker buildx build --platform $(ARCHES) --build-arg USQUE_REF=$(REF) \
		-t $(IMAGE_TAG) $(BUILDX_OUT) .

## hub: мультиарх-сборка и пуш в Docker Hub (сначала docker login, см. README)
hub:
	@test -n "$(HUB_USER)" || { echo "укажите логин: make hub HUB_USER=<логин> [TAG=v1.0.0]"; exit 1; }
	docker buildx build --platform $(ARCHES) --build-arg USQUE_REF=$(REF) \
		-t $(HUB_USER)/$(HUB_REPO):$(TAG) -t $(HUB_USER)/$(HUB_REPO):latest --push .

## binfmt: включить запуск чужих архитектур (нужен --privileged, ставится на хост)
binfmt:
	docker run --privileged --rm tonistiigi/binfmt --install amd64,arm64,arm

## up: поднять контейнер (сборка при необходимости)
up:
	docker compose up -d --build

## down: остановить и удалить контейнер
down:
	docker compose down

## logs: смотреть логи (Ctrl+C для выхода)
logs:
	docker compose logs -f --tail=100 usque

## ps: статус контейнера и healthcheck
ps:
	docker compose ps

## restart: перезапустить контейнер
restart:
	docker compose restart usque

## shell: зайти внутрь контейнера (bash)
shell:
	docker compose exec usque bash

## dryrun: показать, какая команда usque будет запущена, и выйти
dryrun:
	docker compose run --rm -e USQUE_DRYRUN=1 --entrypoint /usr/local/bin/entrypoint.sh usque

## register: зарегистрировать новое устройство WARP (перезапишет config.json!)
register:
	docker compose run --rm -e USQUE_MODE=register --entrypoint /usr/local/bin/entrypoint.sh usque

## enroll: переобучить ключ/адреса по текущему конфигу (полезно для Zero Trust)
enroll:
	docker compose run --rm -e USQUE_MODE=enroll --entrypoint /usr/local/bin/entrypoint.sh usque

## test-routes: проверить логику маршрутизации в изолированном netns (безопасно)
test-routes: build
	docker run --rm --cap-add NET_ADMIN \
		-v "$(CURDIR)/hooks/route-hook.sh:/hook.sh:ro" \
		-v "$(CURDIR)/tests/test-routes.sh:/test.sh:ro" \
		--entrypoint sh alpine:3.22 \
		-c "apk add --no-cache bash iproute2 >/dev/null 2>&1 && bash /test.sh"

## test-modes: проверить сборку аргументов всех режимов (тестовый конфиг, без сети)
test-modes: build test-config
	docker run --rm --cap-add NET_ADMIN --device-cgroup-rule 'c 10:200 rwm' \
		-v "$(TESTCFG):/etc/usque" \
		-v "$(CURDIR)/tests/test-modes.sh:/test.sh:ro" \
		--entrypoint bash $(IMAGE) /test.sh

## test-config: создать одноразовый тестовый конфиг (endpoint 127.0.0.1)
test-config:
	@./tests/make-test-config.sh "$(TESTCFG)"

## check: проверить валидность compose-файла
check:
	docker compose config -q && echo "compose: ок"

## clean: удалить локальный образ
clean:
	-docker rmi $(IMAGE)

.PHONY: help build buildx hub binfmt up down logs ps restart shell dryrun \
        register enroll test-routes test-modes test-config check clean
