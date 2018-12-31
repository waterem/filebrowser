#!/bin/sh

set -e

untracked="(untracked)"
REPO=$(cd $(dirname $0); pwd)
LINT="false"
BUILD="false"
PUSH_LATEST="false"
RELEASE=""

debugInfo () {
  echo "Repo:                     $REPO"
  echo "Will lint:                $LINT"
  echo "Will build:               $BUILD"
  echo "Will release:             $RELEASE"
  echo "Will push latest docker:  $PUSH_LATEST"
  echo "Use Docker:               $USE_DOCKER"
  echo "Is CI:                    $CI"
}

dockerLogin () {
  if [ "$CI" = "true" ]; then
    gpg --batch --gen-key <<-EOF
%echo Generating a standard key
Key-Type: DSA
Key-Length: 1024
Subkey-Type: ELG-E
Subkey-Length: 1024
Name-Real: Meshuggah Rocks
Name-Email: meshuggah@example.com
Expire-Date: 0
# Do a commit here, so that we can later print "done" :-)
%commit
%echo done
EOF

    key=$(gpg --no-auto-check-trustdb --list-secret-keys | grep ^sec | cut -d/ -f2 | cut -d" " -f1)
    pass init $key

    if [ "$(command -v docker-credential-pass)" = "" ]; then
      docker run --rm -itv /usr/local/bin:/src filebrowser/dev sh -c "cp /go/bin/docker-credential-pass /src"
    fi

    echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
  fi
}

dockerLogout () {
  if [ "$CI" = "true" ]; then
    docker logout
  fi
}

dockerPushLatest () {
  docker build -t filebrowser/filebrowser .
  dockerLogin
  docker push filebrowser/filebrowser
  dockerLogout
}

dockerPushTag () {
  dockerLogin

  for tag in `echo $(docker images filebrowser/filebrowser* | awk -F ' ' '{print $1 ":" $2}') | cut -d ' ' -f2-`; do
    if [ "$tag" = "REPOSITORY:TAG" ]; then break; fi
    docker push $tag
  done

  dockerLogout
}

installRice () {
  if ! [ -x "$(command -v rice)" ]; then
    go get github.com/GeertJohan/go.rice/rice
  fi
}

buildAssets () {
  installRice
  cd $REPO/frontend

  if [ -d "dist" ]; then
    rm -rf dist/*
  fi;

  yarn install
  yarn build

  cd $REPO/http
  rice embed-go
}

updateVersion () {
  from=$1
  to=$2

  echo "Updating version from \"$from\" to \"$to\""
  sed -i.bak "s|$from|$to|g" $REPO/types/version.go
}

buildBinary () {
  cd $REPO
  go get -v ./...
  updateVersion $untracked "($COMMIT_SHA)"
  echo "Build CLI"
  CGO_ENABLED=0 go build -a -o filebrowser
  updateVersion "($COMMIT_SHA)" $untracked
}

lint () {
  cd $REPO
  dolint='gometalinter --exclude="rice-box.go" --exclude="vendor" --deadline=300s ./...'
  WDIR="/go/src/github.com/filebrowser/filebrowser"

  if [ "$USE_DOCKER" != "" ]; then
    $(command -v winpty) docker run --rm -itv "/$(pwd):/$WDIR" -w "/$WDIR" filebrowser/dev sh -c "\
      GO111MODULE=on go get -v ./... && \
      GO111MODULE=on go mod vendor && \
      GO111MODULE=off $dolint"
  else
    $dolint
  fi
}

pushRicebox () {
  COMMIT_SHA="$(git rev-parse --verify HEAD | cut -c1-8)"

  cd $REPO

  eval `ssh-agent -s`
  openssl aes-256-cbc -K $encrypted_9ca81b5594f5_key -iv $encrypted_9ca81b5594f5_iv -in ./.ci/deploy_key.enc -d | ssh-add -

  git clone git@github.com:filebrowser/caddy caddy
  cd caddy
  cp $base/http/rice-box.go assets/
  sed -i 's/package lib/package assets/g' assets/rice-box.go
  git checkout -b update-rice-box origin/master
  git config --local user.name "Filebrowser Bot"
  git config --local user.email "FilebrowserBot@users.noreply.github.com"
  git commit -am "update rice-box $COMMIT_SHA"

  if [ $(git tag | grep "$TRAVIS_TAG" | wc -l) -ne 0 ]; then
    git tag -d "$TRAVIS_TAG"
  fi

  git tag "$TRAVIS_TAG"

  if [ "$(git ls-remote --heads origin update-rice-box)" != "" ]; then
    git push -u origin update-rice-box
  else
    git push origin +update-rice-box
  fi

  if [ "$(git ls-remote --heads origin update-rice-box)" != "" ]; then
    git push origin "$TRAVIS_TAG"
  else
    git push origin :"$TRAVIS_TAG"
    git push origin "$TRAVIS_TAG"
  fi
}

ciRelease () {
  docker run --rm -itv $(pwd):/go/src/github.com/filebrowser/filebrowser \
    -v /var/run/docker.sock:/var/run/docker.sock filebrowser/dev goreleaser

  dockerPushTag
  pushRicebox
}

build () {
  cd $REPO

  if [ -d http/"rice-box.go" ]; then
    rm -rf http/rice-box.go
  fi

  if [ "$USE_DOCKER" != "" ]; then
    if [ -d "frontend/dist" ]; then
      rm -rf frontend/dist
    fi;

    if [ "$(command -v git)" != "" ]; then
      COMMIT_SHA="$(git rev-parse HEAD | cut -c1-8)"
    else
      COMMIT_SHA="untracked"
    fi

    $(command -v winpty) docker run -it \
      --name filebrowser-tmp \
      -v /$(pwd):/src:z \
      -w //src \
      -e COMMIT_SHA=$COMMIT_SHA \
      filebrowser/dev \
      sh -c "dos2unix wizard.sh && ./wizard.sh -b"
    exitcode=$?
    
    # TODO: remove echo
    echo "2nd phase"

    if [ $exitcode -eq 0 ]; then
      ls -l $REPO
      for d in "dist/" "node_modules/"; do
        docker cp filebrowser-tmp://src/frontend/$d frontend
      done
      docker cp filebrowser-tmp://src/filebrowser ./filebrowser
      docker cp filebrowser-tmp://src/http/rice-box.go ./http/rice-box.go
    else
      echo "BUILD FAILED!"
    fi
    docker rm -f filebrowser-tmp
  else
    buildAssets
    buildBinary
  fi
}

release () {
  cd $REPO

  echo "> Checking semver format"

  if [ $# -ne 1 ]; then
    echo "This release script requires a single argument corresponding to the semver to be released. See semver.org"
    exit 1
  fi

  semver=$(echo "$1" | grep -P '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)')

  if [ $? -ne 0 ]; then
    echo "Not valid semver format. See semver.org"
    exit 1
  fi

  echo "> Checking matching $semver in frontend submodule"

  cd frontend
  git fetch --all

  if [ $(git tag | grep "$semver" | wc -l) -eq 0 ]; then
    echo "Tag $semver does not exist in submodule 'frontend'. Tag it and run this script again."
    exit 1
  fi

  git rev-parse --verify --quiet release
  if [ $? -ne 0 ]; then
    git checkout -b release "$semver"
  else
    git checkout release
    git reset --hard "$semver"
  fi

  cd ..

  echo "> Updating submodule ref to $semver"
  updateVersion $untracked $1
  git commit -am "chore: version $semver"
  git tag "$1"
  git push
  git push --tags

  echo "> Commiting untracked version notice..."
  updateVersion $1 $untracked
  git commit -am "chore: setting untracked version [ci skip]"
  git push

  echo "> Done!"
}

usage() {
  echo "Usage: $0 [-l] [-b] [-p] [-r <string>]" 1>&2;
  exit 1;
}

DEBUG="false"

while getopts "pdlbr:" o; do
  case "${o}" in
    l)
      LINT="true"
      ;;
    b)
      BUILD="true"
      ;;
    r)
      RELEASE=${OPTARG}
      ;;
    p)
      PUSH_LATEST="true"
      ;;
    d)
      DEBUG="true"
      ;;
    *)
      usage
      ;;
  esac
done
shift $((OPTIND-1))

if [ "$DEBUG" = "true" ]; then
  debugInfo
fi

if [ "$LINT" = "true" ]; then
  lint
fi

if [ "$BUILD" = "true" ]; then
  build
fi

if [ "$PUSH_LATEST" = "true" ]; then
  dockerPushLatest
fi

if [ "$RELEASE" != "" ]; then
  if [ "$CI" = "true" ]; then
    ciRelease
  else
    release $RELEASE
  fi
fi
