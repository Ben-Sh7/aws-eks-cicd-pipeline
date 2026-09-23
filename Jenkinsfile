pipeline {
    agent {
        kubernetes {
            yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-agent
  nodeSelector:
    workload: jenkins
  tolerations:
    - key: workload
      operator: Equal
      value: jenkins
      effect: NoSchedule
  containers:
    - name: aws
      image: amazon/aws-cli:2.37.1
      command: ["cat"]
      tty: true
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi
    - name: helm
      image: alpine/helm:3.22.0
      command: ["cat"]
      tty: true
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi
    - name: promtool
      image: prom/prometheus:v3.0.1
      command: ["cat"]
      tty: true
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi
    - name: trivy
      image: aquasec/trivy:0.74.0
      command: ["cat"]
      tty: true
      resources:
        requests:
          cpu: 100m
          memory: 512Mi
        limits:
          memory: 1Gi
    - name: buildkit
      image: moby/buildkit:v0.33.0-rootless
      args: ["--addr", "unix:///run/user/1000/buildkit/buildkitd.sock", "--oci-worker-no-process-sandbox"]
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: Unconfined
      resources:
        requests:
          cpu: 500m
          memory: 1Gi
        limits:
          memory: 3Gi
      volumeMounts:
        - name: buildkitd
          mountPath: /home/user/.local/share/buildkit
  volumes:
    - name: buildkitd
      emptyDir: {}
'''
        }
    }

    environment {
        AWS_REGION = 'us-east-1'
        BACKEND_REPO = 'devops-task-manager-backend'
        FRONTEND_REPO = 'devops-task-manager-frontend'
        GITOPS_VALUES_FILE = 'gitops/task-manager/values-images.yaml'
        GITOPS_REPO_URL = 'github.com/Ben-Sh7/aws-eks-cicd-pipeline.git'
        APP_DIR = 'app/'
        CHART_DIR = 'gitops/task-manager'
        CHART_STUB_VALUES = 'backend.image.repository=ci,backend.image.tag=ci,frontend.image.repository=ci,frontend.image.tag=ci,config.dbHost=ci,config.appUrl=https://ci.invalid,ingress.host=ci.invalid,secrets.awsSecretName=ci,secrets.jwtSecretName=ci,secrets.appDbSecretName=ci,secrets.dbMonitorSecretName=ci'
        CI_BOT_NAME = 'jenkins-ci-bot'
        CI_BOT_EMAIL = 'jenkins-ci-bot@users.noreply.github.com'
        BUILDKIT_HOST = 'unix:///run/user/1000/buildkit/buildkitd.sock'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.VERSION = sh(script: "git log -1 --first-parent --abbrev=7 --format=%h -- ${APP_DIR}", returnStdout: true).trim()
                    echo "Images are built from ${APP_DIR}, last changed in ${env.VERSION}"
                }
            }
        }

        stage('Resolve ECR registry') {
            steps {
                container('aws') {
                    script {
                        def account = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
                        env.ECR_REGISTRY = "${account}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                        echo "ECR registry: ${env.ECR_REGISTRY}"
                    }
                }
            }
        }

        stage('Guard: skip CI-authored commits') {
            steps {
                script {
                    def lastAuthor = sh(script: "git log -1 --pretty=%an", returnStdout: true).trim()
                    def pushTriggered = !currentBuild.getBuildCauses('com.cloudbees.jenkins.GitHubPushCause').isEmpty()
                    env.SKIP_BUILD = (pushTriggered && lastAuthor == env.CI_BOT_NAME) ? 'true' : 'false'
                    if (env.SKIP_BUILD == 'true') {
                        echo "Last commit was by ${env.CI_BOT_NAME} - skipping to avoid a loop."
                    }
                }
            }
        }

        stage('Guard: skip commits already in ECR') {
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                container('aws') {
                    script {
                        def backend = sh(script: "aws ecr describe-images --repository-name ${BACKEND_REPO} --image-ids imageTag=${env.VERSION} --region ${AWS_REGION} > /dev/null 2>&1", returnStatus: true)
                        def frontend = sh(script: "aws ecr describe-images --repository-name ${FRONTEND_REPO} --image-ids imageTag=${env.VERSION} --region ${AWS_REGION} > /dev/null 2>&1", returnStatus: true)
                        env.IMAGE_EXISTS = (backend == 0 && frontend == 0) ? 'true' : 'false'
                        if (env.IMAGE_EXISTS == 'true') {
                            echo "${env.VERSION} is already in ECR - reusing it instead of rebuilding."
                        }
                    }
                }
            }
        }

        stage('Validate the chart and its alert rules') {
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                echo "Rendering the chart and checking its PromQL - a bad expression fails here instead of at sync time"
                container('helm') {
                    sh '''
                        helm lint ${CHART_DIR} --set-string ${CHART_STUB_VALUES}
                        helm template check ${CHART_DIR} --set-string ${CHART_STUB_VALUES} > rendered.yaml
                        helm template check ${CHART_DIR} --set-string ${CHART_STUB_VALUES} \
                            -s templates/prometheusrule.yaml \
                            | sed -n '/^spec:/,$p' | tail -n +2 | sed 's/^  //' > rules.yaml
                    '''
                }
                container('promtool') {
                    sh 'promtool check rules rules.yaml'
                }
            }
        }

        stage('Sign in to ECR') {
            when { expression { env.SKIP_BUILD != 'true' && env.IMAGE_EXISTS != 'true' } }
            steps {
                echo "Writing a registry credential the builder can use - the pod's own IAM identity earns it"
                container('aws') {
                    sh '''
                        mkdir -p ${WORKSPACE}/.docker
                        printf '{"auths":{"%s":{"auth":"%s"}}}' \
                            "${ECR_REGISTRY}" \
                            "$(printf 'AWS:%s' "$(aws ecr get-login-password --region ${AWS_REGION})" | base64 -w0)" \
                            > ${WORKSPACE}/.docker/config.json
                    '''
                }
            }
        }

        stage('Build images') {
            when { expression { env.SKIP_BUILD != 'true' && env.IMAGE_EXISTS != 'true' } }
            steps {
                echo "Building with BuildKit, to a local file first - nothing reaches ECR before it is scanned"
                container('buildkit') {
                    sh '''
                        for app in backend frontend; do
                            buildctl build \
                                --frontend dockerfile.v0 \
                                --local context=app/${app} \
                                --local dockerfile=app/${app} \
                                --output type=docker,name=${app}:${VERSION},dest=${WORKSPACE}/${app}.tar
                        done
                    '''
                }
            }
        }

        stage('Scan images for CVEs (Trivy)') {
            when { expression { env.SKIP_BUILD != 'true' && env.IMAGE_EXISTS != 'true' } }
            steps {
                echo "Scanning the built files for HIGH/CRITICAL CVEs - fails the build before anything reaches ECR"
                container('trivy') {
                    sh '''
                        for app in backend frontend; do
                            trivy image --input ${WORKSPACE}/${app}.tar \
                                --cache-dir ${WORKSPACE}/.trivy \
                                --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed
                        done
                    '''
                }
            }
        }

        stage('Push to ECR') {
            when { expression { env.SKIP_BUILD != 'true' && env.IMAGE_EXISTS != 'true' } }
            steps {
                echo "Pushing images to ECR with tag: ${env.VERSION}"
                container('buildkit') {
                    sh '''
                        export DOCKER_CONFIG=${WORKSPACE}/.docker

                        buildctl build \
                            --frontend dockerfile.v0 \
                            --local context=app/backend \
                            --local dockerfile=app/backend \
                            --output type=image,name=${ECR_REGISTRY}/${BACKEND_REPO}:${VERSION},push=true

                        buildctl build \
                            --frontend dockerfile.v0 \
                            --local context=app/frontend \
                            --local dockerfile=app/frontend \
                            --output type=image,name=${ECR_REGISTRY}/${FRONTEND_REPO}:${VERSION},push=true
                    '''
                }
            }
        }

        stage('Update GitOps Values') {
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'github-credentials', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
                    sh '''
                        git config user.name "${CI_BOT_NAME}"
                        git config user.email "${CI_BOT_EMAIL}"

                        for attempt in 1 2 3; do
                            git fetch --quiet origin main
                            git checkout --quiet -B deploy FETCH_HEAD

                            LATEST=$(git log -1 --first-parent --abbrev=7 --format=%h -- ${APP_DIR})
                            if [ "$LATEST" != "${VERSION}" ]; then
                                echo "main already has newer app code (${LATEST}) - that build owns the deploy."
                                exit 0
                            fi

                            cat > ${GITOPS_VALUES_FILE} << YAML
backend:
  image:
    repository: ${ECR_REGISTRY}/${BACKEND_REPO}
    tag: "${VERSION}"

frontend:
  image:
    repository: ${ECR_REGISTRY}/${FRONTEND_REPO}
    tag: "${VERSION}"
YAML

                            git add ${GITOPS_VALUES_FILE}
                            if git diff --cached --quiet; then
                                echo "${GITOPS_VALUES_FILE} already points at ${VERSION} - nothing to deploy."
                                exit 0
                            fi

                            git commit --quiet -m "ci: deploy ${VERSION}"

                            if git push --quiet https://${GIT_USER}:${GIT_TOKEN}@${GITOPS_REPO_URL} HEAD:main; then
                                exit 0
                            fi

                            echo "main moved while pushing - retrying on top of it (attempt ${attempt})"
                        done

                        echo "Could not land the deploy commit after 3 attempts."
                        exit 1
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Build ${env.BUILD_NUMBER} finished: ${env.VERSION}"
        }
        failure {
            echo "Build ${env.BUILD_NUMBER} failed"
        }
    }
}
