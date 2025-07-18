#Copyright 2022 The Kubernetes Authors
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License.
#You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS,
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#See the License for the specific language governing permissions and
#limitations under the License.
SHELL = /bin/bash

# MP CSI Driver version
VERSION=1.15.0

PKG=github.com/awslabs/mountpoint-s3-csi-driver
GIT_COMMIT?=$(shell git rev-parse HEAD)
BUILD_DATE?=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

LDFLAGS?="-X ${PKG}/pkg/driver/version.driverVersion=${VERSION} -X ${PKG}/pkg/driver/version.gitCommit=${GIT_COMMIT} -X ${PKG}/pkg/driver/version.buildDate=${BUILD_DATE}"

GO111MODULE=on
GOPROXY=direct
GOPATH=$(shell go env GOPATH)
GOOS=$(shell go env GOOS)
GOBIN=$(GOPATH)/bin

REGISTRY?=""
IMAGE_NAME?=""
IMAGE?=$(REGISTRY)/${IMAGE_NAME}
TAG?=$(GIT_COMMIT)

DOCKERFILE?="Dockerfile"

OS?=linux
ARCH?=amd64
OSVERSION?=amazon

ALL_OS?=linux
ALL_ARCH_linux?=amd64 arm64
ALL_OSVERSION_linux?=amazon
ALL_OS_ARCH_OSVERSION_linux=$(foreach arch, $(ALL_ARCH_linux), $(foreach osversion, ${ALL_OSVERSION_linux}, linux-$(arch)-${osversion}))
ALL_OS_ARCH_OSVERSION=$(foreach os, $(ALL_OS), ${ALL_OS_ARCH_OSVERSION_${os}})

PLATFORM?=linux/amd64,linux/arm64

# List of allowed licenses in the CSI Driver's dependencies.
# See https://github.com/google/licenseclassifier/blob/e6a9bb99b5a6f71d5a34336b8245e305f5430f99/license_type.go#L28 for list of cannonical names for licenses.
ALLOWED_LICENSES="Apache-2.0,BSD-2-Clause,BSD-3-Clause,ISC,MIT"

# region is expected to be the same where cluster is created
E2E_REGION?=us-east-1
E2E_COMMIT_ID?=local
E2E_KUBECONFIG?=""

# Kubernetes version to use in envtest for controller tests.
ENVTEST_K8S_VERSION ?= 1.30.x

# split words on hyphen, access by 1-index
word-hyphen = $(word $2,$(subst -, ,$1))

.EXPORT_ALL_VARIABLES:

# Builds all linux images (not windows because it can't be exported with OUTPUT_TYPE=docker)
.PHONY: all
all: all-image-docker

# Builds all images and pushes them
.PHONY: all-push
all-push: create-and-push-manifest-and-images

# Builds images only if not present with the tag
.PHONY: all-push-skip-if-present
all-push-skip-if-present:
	docker manifest inspect $(IMAGE):$(TAG) > /dev/null || $(MAKE) all-push

.PHONY: build_image
build_image:
	DOCKER_BUILDKIT=1 docker buildx build -f ${DOCKERFILE} -t=${IMAGE}:${TAG} --platform=${PLATFORM} .

.PHONY: push-manifest
push-manifest: create-manifest
	docker manifest push --purge $(IMAGE):$(TAG)

.PHONY: create-and-push-manifest-and-images
create-and-push-manifest-and-images: all-image-registry
# sed expression:
# LHS: match 0 or more not space characters
# RHS: replace with $(IMAGE):$(TAG)-& where & is what was matched on LHS
	docker buildx imagetools create -t $(IMAGE):$(TAG) $(shell echo $(ALL_OS_ARCH_OSVERSION) | sed -e "s~[^ ]*~$(IMAGE):$(TAG)\-&~g")

# Only linux for OUTPUT_TYPE=docker because windows image cannot be exported
# "Currently, multi-platform images cannot be exported with the docker export type. The most common usecase for multi-platform images is to directly push to a registry (see registry)."
# https://docs.docker.com/engine/reference/commandline/buildx_build/#output

.PHONY: all-image-docker
all-image-docker: $(addprefix sub-image-docker-,$(ALL_OS_ARCH_OSVERSION_linux))
.PHONY: all-image-registry
all-image-registry: $(addprefix sub-image-registry-,$(ALL_OS_ARCH_OSVERSION))

sub-image-%:
	$(MAKE) OUTPUT_TYPE=$(call word-hyphen,$*,1) OS=$(call word-hyphen,$*,2) ARCH=$(call word-hyphen,$*,3) OSVERSION=$(call word-hyphen,$*,4) image

.PHONY: image
image: .image-$(TAG)-$(OS)-$(ARCH)-$(OSVERSION)
.image-$(TAG)-$(OS)-$(ARCH)-$(OSVERSION):
	DOCKER_BUILDKIT=1 docker buildx build \
		-f ${DOCKERFILE} \
		--platform=$(OS)/$(ARCH) \
		--progress=plain \
		--target=$(OS)-$(OSVERSION) \
		--output=type=$(OUTPUT_TYPE) \
		-t=$(IMAGE):$(TAG)-$(OS)-$(ARCH)-$(OSVERSION) \
		--build-arg=GOPROXY=$(GOPROXY) \
		--build-arg=VERSION=$(VERSION) \
		--provenance=false \
		.
	touch $@

.PHONY: push_image
push_image:
	docker push ${IMAGE}:${TAG}

.PHONY: login_registry
login_registry:
	aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${REGISTRY}

.PHONY: download_go_deps
download_go_deps:
	go mod download

.PHONY: bin
bin:
	mkdir -p bin
	CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags ${LDFLAGS} -o bin/aws-s3-csi-driver ./cmd/aws-s3-csi-driver/
	CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags ${LDFLAGS} -o bin/aws-s3-csi-controller ./cmd/aws-s3-csi-controller/
	CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags ${LDFLAGS} -o bin/aws-s3-csi-mounter ./cmd/aws-s3-csi-mounter/
	# TODO: `install-mp` component won't be necessary with the containerization.
	CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags ${LDFLAGS} -o bin/install-mp ./cmd/install-mp/

.PHONY: install-go-test-coverage
install-go-test-coverage:
	go install github.com/vladopajic/go-test-coverage/v2@latest

.PHONY: test
test:
	go test -v -race ./{cmd,pkg}/... -coverprofile=./cover.out -covermode=atomic -coverpkg=./{cmd,pkg}/...
	# skipping controller test cases because we don't implement controller for static provisioning,
	# this is a known limitation of sanity testing package: https://github.com/kubernetes-csi/csi-test/issues/214
	go test -v ./tests/sanity/... -ginkgo.skip="ControllerGetCapabilities" -ginkgo.skip="ValidateVolumeCapabilities"

.PHONY: cover
cover:
	${GOBIN}/go-test-coverage --config=./.testcoverage.yml
	go tool cover -html=cover.out -o=cover.html

.PHONY: fmt
fmt:
	go fmt ./...

# Run controller tests with envtest.
.PHONY: e2e-controller
e2e-controller: envtest
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(TOOLS_BIN) -p path)" go test ./tests/controller/... -ginkgo.v -test.v

.PHONY: e2e
e2e: e2e-controller
	pushd tests/e2e-kubernetes; \
	KUBECONFIG=${E2E_KUBECONFIG} ginkgo -p -vv -timeout 60m -- --bucket-region=${E2E_REGION} --commit-id=${E2E_COMMIT_ID}; \
	EXIT_CODE=$$?; \
	popd; \
	exit $$EXIT_CODE

.PHONY: check_style
check_style:
	test -z "$$(gofmt -d . | tee /dev/stderr)"

.PHONY: check_licenses
check_licenses: download_go_deps
	go tool github.com/google/go-licenses/v2 check --allowed_licenses ${ALLOWED_LICENSES} ./...

.PHONY: generate_licenses
generate_licenses: download_go_deps
	go tool github.com/google/go-licenses/v2 save --save_path="./LICENSES" --force ./...

.PHONY: clean
clean:
	rm -rf bin/ && docker system prune

# Generate files for Custom Resources (`zz_generated.deepcopy.go` and CustomResourceDefinition YAML file).
TMP_POD_ATTACHMENT_CRD_FILE ?= "./hack/s3.csi.aws.com_mountpoints3podattachments.yaml"
# Helm CRD file needs extra `{{- if .Values.experimental.podMounter -}}` wrapper, while we don't need it for tests.
HELM_POD_ATTACHMENT_CRD_FILE ?= "./charts/aws-mountpoint-s3-csi-driver/templates/mountpoints3podattachments-crd.yaml"
TEST_POD_ATTACHMENT_CRD_FILE ?= "./tests/crd/mountpoints3podattachments-crd.yaml"
.PHONY: generate
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./pkg/api/..."
	$(CONTROLLER_GEN) crd paths="./pkg/api/..." output:crd:dir=./hack/
	echo '# Auto-generated file via `make generate`. Do not edit.' > $(HELM_POD_ATTACHMENT_CRD_FILE)
	echo '{{- if .Values.experimental.podMounter -}}' >> $(HELM_POD_ATTACHMENT_CRD_FILE)
	cat $(TMP_POD_ATTACHMENT_CRD_FILE) >> $(HELM_POD_ATTACHMENT_CRD_FILE)
	echo '{{- end -}}' >> $(HELM_POD_ATTACHMENT_CRD_FILE)
	echo '# Auto-generated file via `make generate`. Do not edit.' > $(TEST_POD_ATTACHMENT_CRD_FILE)
	cat $(TMP_POD_ATTACHMENT_CRD_FILE) >> $(TEST_POD_ATTACHMENT_CRD_FILE)
	rm $(TMP_POD_ATTACHMENT_CRD_FILE)

## Tool Binaries

TOOLS_BIN ?= $(shell pwd)/tools/bin
$(TOOLS_BIN):
	mkdir -p $(TOOLS_BIN)

CONTROLLER_GEN ?= $(TOOLS_BIN)/controller-gen
ENVTEST ?= $(TOOLS_BIN)/setup-envtest

CONTROLLER_GEN_VERSION ?= v0.17.3
ENVTEST_VERSION ?= release-0.19

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN)
$(CONTROLLER_GEN): $(TOOLS_BIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_GEN_VERSION))

.PHONY: envtest
envtest: $(ENVTEST)
$(ENVTEST): $(TOOLS_BIN)
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(ENVTEST_VERSION))

# Copied from https://github.com/kubernetes-sigs/kubebuilder/blob/c32f9714456f7e5e7cc6c790bb87c7e5956e710b/pkg/plugins/golang/v4/scaffolds/internal/templates/makefile.go#L275-L289.
# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f $(1) || true ;\
GOBIN=$(TOOLS_BIN) go install $${package} ;\
mv $(1) $(1)-$(3) ;\
} ;\
ln -sf $(1)-$(3) $(1)
endef
