#!/usr/bin/env bash

# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# This script builds and pushes docker images when run from a release of Spark
# with Kubernetes support.

function error {
  echo "$@" 1>&2
  exit 1
}

if [ -z "${SPARK_HOME}" ]; then
  SPARK_HOME="$(cd "`dirname "$0"`"/..; pwd)"
fi
. "${SPARK_HOME}/bin/load-spark-env.sh"

function image_ref {
  local image="$1"
  local add_repo="${2:-1}"
  if [ $add_repo = 1 ] && [ -n "$REPO" ]; then
    image="$REPO/$image"
  fi
  if [ -n "$TAG" ]; then
    image="$image:$TAG"
  fi
  echo "$image"
}

function docker_push {
  local image_name="$1"
  if [ ! -z $(docker images -q "$(image_ref ${image_name})") ]; then
    docker push "$(image_ref ${image_name})"
    if [ $? -ne 0 ]; then
      error "Failed to push $image_name Docker image."
    fi
  else
    echo "$(image_ref ${image_name}) image not found. Skipping push for this image."
  fi
}

function build {
  local BUILD_ARGS
  local IMG_PATH
  local JARS

  if [ ! -f "$SPARK_HOME/RELEASE" ]; then
    # Set image build arguments accordingly if this is a source repo and not a distribution archive.
    #
    # Note that this will copy all of the example jars directory into the image, and that will
    # contain a lot of duplicated jars with the main Spark directory. In a proper distribution,
    # the examples directory is cleaned up before generating the distribution tarball, so this
    # issue does not occur.
    IMG_PATH=resource-managers/kubernetes/docker/src/main/dockerfiles
    JARS=assembly/target/scala-$SPARK_SCALA_VERSION/jars
    BUILD_ARGS=(
      ${BUILD_PARAMS}
      --build-arg
      img_path=$IMG_PATH
      --build-arg
      spark_jars=$JARS
      --build-arg
      example_jars=examples/target/scala-$SPARK_SCALA_VERSION/jars
      --build-arg
      k8s_tests=resource-managers/kubernetes/integration-tests/tests
    )
  else
    # Not passed as arguments to docker, but used to validate the Spark directory.
    IMG_PATH="kubernetes/dockerfiles"
    JARS=jars
    BUILD_ARGS=(${BUILD_PARAMS})
  fi

  # Verify that the Docker image content directory is present
  if [ ! -d "$IMG_PATH" ]; then
    error "Cannot find docker image. This script must be run from a runnable distribution of Apache Spark."
  fi

  # Verify that Spark has actually been built/is a runnable distribution
  # i.e. the Spark JARs that the Docker files will place into the image are present
  local TOTAL_JARS=$(ls $JARS/spark-* | wc -l)
  TOTAL_JARS=$(( $TOTAL_JARS ))
  if [ "${TOTAL_JARS}" -eq 0 ]; then
    error "Cannot find Spark JARs. This script assumes that Apache Spark has first been built locally or this is a runnable distribution."
  fi

  local BINDING_BUILD_ARGS=(
    ${BUILD_PARAMS}
    --build-arg
    base_img=$(image_ref spark)
  )
  local BASEDOCKERFILE=${BASEDOCKERFILE:-"$IMG_PATH/spark/Dockerfile"}
  local PYDOCKERFILE=${PYDOCKERFILE:-false}
  local RDOCKERFILE=${RDOCKERFILE:-false}

  docker build $NOCACHEARG "${BUILD_ARGS[@]}" \
    -t $(image_ref spark) \
    -f "$BASEDOCKERFILE" .
  if [ $? -ne 0 ]; then
    error "Failed to build Spark JVM Docker image, please refer to Docker build output for details."
  fi

  if [ "${PYDOCKERFILE}" != "false" ]; then
    docker build $NOCACHEARG "${BINDING_BUILD_ARGS[@]}" \
      -t $(image_ref spark-py) \
      -f "$PYDOCKERFILE" .
      if [ $? -ne 0 ]; then
        error "Failed to build PySpark Docker image, please refer to Docker build output for details."
      fi
  fi

  if [ "${RDOCKERFILE}" != "false" ]; then
    docker build $NOCACHEARG "${BINDING_BUILD_ARGS[@]}" \
      -t $(image_ref spark-r) \
      -f "$RDOCKERFILE" .
    if [ $? -ne 0 ]; then
      error "Failed to build SparkR Docker image, please refer to Docker build output for details."
    fi
  fi
}

function push {
  docker_push "spark"
  docker_push "spark-py"
  docker_push "spark-r"
}

function usage {
  cat <<EOF
Usage: $0 [options] [command]
Builds or pushes the built-in Spark Docker image.

Commands:
  build       Build image. Requires a repository address to be provided if the image will be
              pushed to a different registry.
  push        Push a pre-built image to a registry. Requires a repository address to be provided.

Options:
  -f file               Dockerfile to build for JVM based Jobs. By default builds the Dockerfile shipped with Spark.
  -p file               (Optional) Dockerfile to build for PySpark Jobs. Builds Python dependencies and ships with Spark.
                        Skips building PySpark docker image if not specified.
  -R file               (Optional) Dockerfile to build for SparkR Jobs. Builds R dependencies and ships with Spark.
                        Skips building SparkR docker image if not specified.
  -r repo               Repository address.
  -t tag                Tag to apply to the built image, or to identify the image to be pushed.
  -m                    Use minikube's Docker daemon.
  -n                    Build docker image with --no-cache
  -b arg      Build arg to build or push the image. For multiple build args, this option needs to
              be used separately for each build arg.

Using minikube when building images will do so directly into minikube's Docker daemon.
There is no need to push the images into minikube in that case, they'll be automatically
available when running applications inside the minikube cluster.

Check the following documentation for more information on using the minikube Docker daemon:

  https://kubernetes.io/docs/getting-started-guides/minikube/#reusing-the-docker-daemon

Examples:
  - Build image in minikube with tag "testing"
    $0 -m -t testing build

  - Build PySpark docker image
    $0 -r docker.io/myrepo -t v2.3.0 -p kubernetes/dockerfiles/spark/bindings/python/Dockerfile build

  - Build and push image with tag "v2.3.0" to docker.io/myrepo
    $0 -r docker.io/myrepo -t v2.3.0 build
    $0 -r docker.io/myrepo -t v2.3.0 push
EOF
}

if [[ "$@" = *--help ]] || [[ "$@" = *-h ]]; then
  usage
  exit 0
fi

REPO=
TAG=
BASEDOCKERFILE=
PYDOCKERFILE=
RDOCKERFILE=
NOCACHEARG=
BUILD_PARAMS=
while getopts f:p:R:mr:t:nb: option
do
 case "${option}"
 in
 f) BASEDOCKERFILE=${OPTARG};;
 p) PYDOCKERFILE=${OPTARG};;
 R) RDOCKERFILE=${OPTARG};;
 r) REPO=${OPTARG};;
 t) TAG=${OPTARG};;
 n) NOCACHEARG="--no-cache";;
 b) BUILD_PARAMS=${BUILD_PARAMS}" --build-arg "${OPTARG};;
 m)
   if ! which minikube 1>/dev/null; then
     error "Cannot find minikube."
   fi
   if ! minikube status 1>/dev/null; then
     error "Cannot contact minikube. Make sure it's running."
   fi
   eval $(minikube docker-env)
   ;;
 esac
done

case "${@: -1}" in
  build)
    build
    ;;
  push)
    if [ -z "$REPO" ]; then
      usage
      exit 1
    fi
    push
    ;;
  *)
    usage
    exit 1
    ;;
esac
