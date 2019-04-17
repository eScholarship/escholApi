#!/usr/bin/env bash

DEBUG=1
if [[ -n "$DEBUG" ]]; then
  set -x
fi

set -o pipefail  # trace ERR through pipes
set -o errtrace  # trace ERR through 'time command' and other functions
set -o nounset   ## set -u : exit the script if you try to use an uninitialised variable
set -o errexit   ## set -e : exit the script if any statement returns a non-true return value

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # http://stackoverflow.com/questions/59895
cd $DIR

usage(){
    echo "deploy-version.sh environment-name"
    exit 1
}

if [ $# -ne 1 ];
  then
    usage
fi

set -u

export TZ=":America/Los_Angeles"
VERSION=`date -Iseconds`
DIR=escholApi
BUCKET=cdlpub-apps
REGION=us-west-2
APPNAME=pub-escholApi-app

# make sure environment actually exists
env_exists=$(aws elasticbeanstalk describe-environments \
  --environment-name "$1" \
  --no-include-deleted \
  --region $REGION \
  | egrep -c 'Status.*Ready')

if [[ env_exists -ne 1 ]]
  then
    echo "environment $1 does not exist"
    usage
fi

ZIP="escholApi-$VERSION.zip"

# package app and upload
git archive --format=zip HEAD > $ZIP
aws s3 cp $ZIP s3://$BUCKET/$DIR/$ZIP
rm $ZIP

aws elasticbeanstalk create-application-version \
  --application-name $APPNAME \
  --region $REGION \
  --source-bundle S3Bucket=$BUCKET,S3Key=$DIR/$ZIP \
  --version-label "$VERSION"

# deploy app to a running environment
aws elasticbeanstalk update-environment \
  --environment-name "$1" \
  --region $REGION \
  --version-label "$VERSION" \
  --option-settings file://eboptions.json

# Copyright (c) 2018, Regents of the University of California
#
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
# - Redistributions of source code must retain the above copyright notice,
#   this list of conditions and the following disclaimer.
# - Redistributions in binary form must reproduce the above copyright
#   notice, this list of conditions and the following disclaimer in the
#   documentation and/or other materials provided with the distribution.
# - Neither the name of the University of California nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
