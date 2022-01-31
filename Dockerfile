# Use terraform-plan-validator image to get the binaries and default configurations
# https://hub.docker.com/r/bradmccoydev/terraform-plan-validator
FROM bradmccoydev/terraform-plan-validator:7acd227edb8f0b320324ca87e44644e9fffc7a16 as validator

# Use the offical Golang image to create a build artifact.
# This is based on Debian and sets the GOPATH to /go.
# https://hub.docker.com/_/golang
FROM golang:1.16.2-alpine as builder

RUN apk add --no-cache gcc libc-dev git

WORKDIR /src/terraform-service

ARG version=develop
ENV VERSION="${version}"

# Force the go compiler to use modules
ENV GO111MODULE=on
ENV BUILDFLAGS=""
ENV GOPROXY=https://proxy.golang.org

# Copy `go.mod` for definitions and `go.sum` to invalidate the next layer
# in case of a change in the dependencies
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

ARG debugBuild

# set buildflags for debug build
RUN if [ ! -z "$debugBuild" ]; then export BUILDFLAGS='-gcflags "all=-N -l"'; fi

# Copy local code to the container image.
COPY . .

# Build the command inside the container.
# (You may fetch or manage dependencies here, either manually or with a tool like "godep".)
RUN GOOS=linux go build -ldflags '-linkmode=external' $BUILDFLAGS -v -o terraform-service

# Use a Docker multi-stage build to create a lean production image.
# https://docs.docker.com/develop/develop-images/multistage-build/#use-multi-stage-builds
FROM alpine:3.15
ENV ENV=production

# Install extra packages
# See https://github.com/gliderlabs/docker-alpine/issues/136#issuecomment-272703023

RUN    apk update && apk upgrade \
	&& apk add --no-cache --virtual .certs-pkgs ca-certificates libc6-compat \
	&& update-ca-certificates \
	&& apk del .certs-pkgs \
	&& rm -rf /var/cache/apk/*

ARG version=develop
ENV VERSION="${version}"

# Copy the binary to the production image from the builder stage.
COPY --from=builder /src/terraform-service/terraform-service /terraform-service


# Set Env Variables for terraform-plan-validator
ENV OPA_GCP_POLICY=opa-gcp-policy.rego
ENV OPA_AZURE_POLICY=opa-azure-policy.rego
ENV OPA_AWS_POLICY=opa-aws-policy.rego
ENV OPA_REGO_QUERY=data.terraform.analysis.authz

# Copy terraform and tf-sec binaries from validator image
COPY --from=validator /usr/local/bin/tfsec /usr/local/bin/tfsec
COPY --from=validator /usr/local/bin/terraform /usr/local/bin/terraform

WORKDIR /terraform-plan-validator
# Copy terraform plan validator binary
COPY --from=validator /terraform-plan-validator terraform-plan-validator
COPY --from=validator terraform-plan-validator /usr/bin/terraform-plan-validator

# Copy terraform plan validator and tf-sec policies
COPY --from=validator /terraform-plan-validator/app.env ./app.env
COPY --from=validator /terraform-plan-validator/opa-azure-policy.rego ./opa-azure-policy.rego
COPY --from=validator /terraform-plan-validator/opa-gcp-policy.rego ./opa-gcp-policy.rego
COPY --from=validator /terraform-plan-validator/app.env /opt/atlassian/pipelines/agent/build

EXPOSE 8080

# required for external tools to detect this as a go binary
ENV GOTRACEBACK=all

# KEEP THE FOLLOWING LINES COMMENTED OUT!!! (they will be included within the travis-ci build)
#build-uncomment ADD MANIFEST /
#build-uncomment COPY entrypoint.sh /
#build-uncomment ENTRYPOINT ["/entrypoint.sh"]

# Run the web service on container startup.
CMD ["/terraform-service"]
