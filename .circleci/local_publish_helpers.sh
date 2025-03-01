#!/bin/bash

custom_registry_url=http://localhost:4873
default_verdaccio_package=verdaccio@5.1.2

function startLocalRegistry {
    # Start local registry
    tmp_registry_log=$(mktemp)
    echo "Registry output file: $tmp_registry_log"
    (cd && nohup npx ${VERDACCIO_PACKAGE:-$default_verdaccio_package} -c $1 &>$tmp_registry_log &)
    # Wait for Verdaccio to boot
    grep -q 'http address' <(tail -f $tmp_registry_log)
}

function setNpmTag {
    if [ -z $NPM_TAG ]; then
        if [[ "$CIRCLE_BRANCH" =~ ^tagged-release ]]; then
            if [[ "$CIRCLE_BRANCH" =~ ^tagged-release-without-e2e-tests\/.* ]]; then
                export NPM_TAG="${CIRCLE_BRANCH/tagged-release-without-e2e-tests\//}"
            elif [[ "$CIRCLE_BRANCH" =~ ^tagged-release\/.* ]]; then
                export NPM_TAG="${CIRCLE_BRANCH/tagged-release\//}"
            fi
        fi
        if [[ "$CIRCLE_BRANCH" == "beta" ]]; then
            export NPM_TAG="beta"
        fi
    else
        echo "NPM tag was already set!"
    fi
    echo $NPM_TAG
}

function unsetNpmRegistryUrl {
    # Restore the original NPM and Yarn registry URLs
    npm set registry "https://registry.npmjs.org/"
    yarn config set registry "https://registry.npmjs.org/"
}

function unsetSudoNpmRegistryUrl {
    # Restore the original NPM and Yarn registry URLs
    sudo npm set registry "https://registry.npmjs.org/"
    sudo yarn config set registry "https://registry.npmjs.org/"
}

function changeNpmGlobalPath {
    mkdir -p ~/.npm-global
    npm config set prefix '~/.npm-global'
    export PATH=~/.npm-global/bin:$PATH
}

function changeSudoNpmGlobalPath {
    mkdir -p ~/.npm-global-sudo
    npm config set prefix '~/.npm-global-sudo'
    export PATH=~/.npm-global/bin:$PATH
}

function setNpmRegistryUrlToLocal {
    # Set registry to local registry
    npm set registry "$custom_registry_url"
    yarn config set registry "$custom_registry_url"
}

function setSudoNpmRegistryUrlToLocal {
    # Set registry to local registry
    sudo npm set registry "$custom_registry_url"
    sudo yarn config set registry "$custom_registry_url"
}

function useChildAccountCredentials {
    if [ -z "$USE_PARENT_ACCOUNT" ]; then
        export AWS_PAGER=""
        export ORGANIZATION_SIZE=$(aws organizations list-accounts | jq '.Accounts | length')
        export CREDS=$(aws sts assume-role --role-arn arn:aws:iam::$(aws organizations list-accounts | jq -c -r ".Accounts [$(($RANDOM % $ORGANIZATION_SIZE))].Id"):role/OrganizationAccountAccessRole --role-session-name testSession$((1 + $RANDOM % 10000)) --duration-seconds 3600)
        if [ -z $(echo $CREDS | jq -c -r '.AssumedRoleUser.Arn') ]; then
            echo "Unable to assume child account role. Falling back to parent AWS account"
        else
            echo "Using account credentials for $(echo $CREDS | jq -c -r '.AssumedRoleUser.Arn')"
            export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -c -r ".Credentials.AccessKeyId")
            export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -c -r ".Credentials.SecretAccessKey")
            export AWS_SESSION_TOKEN=$(echo $CREDS | jq -c -r ".Credentials.SessionToken")
        fi
    else
        echo "Using parent account credentials."
    fi
}

function retry {
    MAX_ATTEMPTS=2
    SLEEP_DURATION=5
    FIRST_RUN=true
    n=0
    FAILED_TEST_REGEX_FILE="./amplify-e2e-reports/amplify-e2e-failed-test.txt"
    if [ -f  $FAILED_TEST_REGEX_FILE ]; then
        rm -f $FAILED_TEST_REGEX_FILE
    fi
    until [ $n -ge $MAX_ATTEMPTS ]
    do
        echo "Attempting $@ with max retries $MAX_ATTEMPTS"
        setAwsAccountCredentials
        "$@" && break
        n=$[$n+1]
        FIRST_RUN=false
        echo "Attempt $n completed."
        sleep $SLEEP_DURATION
    done
    if [ $n -ge $MAX_ATTEMPTS ]; then
        echo "failed: ${@}" >&2
        exit 1
    fi

    resetAwsAccountCredentials
    TEST_SUITE=${TEST_SUITE:-"TestSuiteNotSet"}
    aws cloudwatch put-metric-data --metric-name FlakyE2ETests --namespace amplify-category-api-e2e-tests --unit Count --value $n --dimensions testFile=$TEST_SUITE
    echo "Attempt $n succeeded."
    exit 0 # don't fail the step if putting the metric fails
}

function resetAwsAccountCredentials {
    if [ -z "$AWS_ACCESS_KEY_ID_ORIG" ]; then
        echo "AWS Access Key environment variable is already set"
    else
        export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID_ORIG
    fi
    if [ -z "$AWS_SECRET_ACCESS_KEY_ORIG" ]; then
        echo "AWS Secret Access Key environment variable is already set"
    else
        export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY_ORIG
    fi
    if [ -z "$AWS_SESSION_TOKEN_ORIG" ]; then
        echo "AWS Session Token environment variable is already set"
    else
        export AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN_ORIG
    fi
}

function setAwsAccountCredentials {
    resetAwsAccountCredentials
    export AWS_ACCESS_KEY_ID_ORIG=$AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY_ORIG=$AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN_ORIG=$AWS_SESSION_TOKEN
    if [[ "$OSTYPE" == "msys" ]]; then
        # windows provided by circleci has this OSTYPE
        useChildAccountCredentials
    else
        echo "OSTYPE is $OSTYPE"
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -o awscliv2.zip >/dev/null
        export PATH=$PATH:$(pwd)/aws/dist
        useChildAccountCredentials
    fi
}

function runE2eTest {
    FAILED_TEST_REGEX_FILE="./amplify-e2e-reports/amplify-e2e-failed-test.txt"

    if [ -z "$FIRST_RUN" ] || [ "$FIRST_RUN" == "true" ]; then
        echo "using Amplify CLI version: "$(amplify --version)
        cd $(pwd)/packages/amplify-e2e-tests
    fi

    if [ -f  $FAILED_TEST_REGEX_FILE ]; then
        # read the content of failed tests
        failedTests=$(<$FAILED_TEST_REGEX_FILE)
        yarn run e2e --detectOpenHandles --maxWorkers=3 $TEST_SUITE -t "$failedTests"
    else
        yarn run e2e --detectOpenHandles --maxWorkers=3 $TEST_SUITE
    fi
}

# Accepts the value as an input parameter, i.e. 1 for success, 0 for failure.
# Only executes if IS_CANARY env variable is set
function emitCanarySuccessMetric {
    if [[ "$CIRCLE_BRANCH" = main ]]; then
        USE_PARENT_ACCOUNT=1
        setAwsAccountCredentials 
        aws cloudwatch \
            put-metric-data \
            --metric-name CanarySuccessRate \
            --namespace amplify-category-api-e2e-tests \
            --unit Count \
            --value 1 \
            --dimensions branch=main \
            --region us-west-2
    fi
}

function emitCanaryFailureMetric {
    if [[ "$CIRCLE_BRANCH" = main ]]; then
        USE_PARENT_ACCOUNT=1
        setAwsAccountCredentials 
        aws cloudwatch \
            put-metric-data \
            --metric-name CanarySuccessRate \
            --namespace amplify-category-api-e2e-tests \
            --unit Count \
            --value 0 \
            --dimensions branch=main \
            --region us-west-2
    fi
}
