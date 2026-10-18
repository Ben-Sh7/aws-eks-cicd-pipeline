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
    - name: jnlp
      image: jenkins/inbound-agent:3391.va_37fa_a_305d6d-5-jdk25
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          memory: 512Mi
    - name: aws
      image: amazon/aws-cli:2.37.10
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
      image: prom/prometheus:v3.15.0
      command: ["cat"]
      tty: true
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi
    - name: trivy
      image: aquasec/trivy:0.75.0
      command: ["cat"]
      tty: true
      resources:
        requests:
          cpu: 100m
          memory: 512Mi
        limits:
          memory: 1Gi
    - name: crane
      image: gcr.io/go-containerregistry/crane/debug:v0.22.1
      command: ["cat"]
      tty: true
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          memory: 256Mi
    - name: buildkit
      image: moby/buildkit:v0.34.0-rootless
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

    options {
        // A second build waits for the first instead of building the same missing image
        // and failing to push it: ECR tags are immutable.
        disableConcurrentBuilds()
    }

    environment {
        AWS_REGION = 'us-east-1'
        BACKEND_REPO = 'devops-task-manager-backend'
        FRONTEND_REPO = 'devops-task-manager-frontend'
        GITOPS_VALUES_FILE = 'gitops/task-manager/values-images.yaml'
        GITOPS_REPO_URL = 'github.com/Ben-Sh7/aws-eks-cicd-pipeline.git'
        CHART_DIR = 'gitops/task-manager'
        CHART_STUB_VALUES = 'backend.image.repository=ci,backend.image.tag=ci,frontend.image.repository=ci,frontend.image.tag=ci,config.dbHost=ci,config.appUrl=https://ci.invalid,ingress.host=ci.invalid,secrets.awsSecretName=ci,secrets.jwtSecretName=ci,secrets.appDbSecretName=ci,secrets.dbMonitorSecretName=ci,secrets.redisSecretName=ci'
        CI_BOT_NAME = 'jenkins-ci-bot'
        // Not <name>@users.noreply.github.com: GitHub credits that format to whoever
        // owns the account of that name - a stranger's, for jenkins-ci-bot.
        CI_BOT_EMAIL = 'jenkins-ci-bot@ben-sharabi.com'
        BUILDKIT_HOST = 'unix:///run/user/1000/buildkit/buildkitd.sock'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    // Each image is tagged with the last commit that changed its own folder,
                    // so a change to one side builds and rolls out that side only.
                    env.BACKEND_VERSION = sh(script: 'git log -1 --first-parent --abbrev=7 --format=%h -- app/backend', returnStdout: true).trim()
                    env.FRONTEND_VERSION = sh(script: 'git log -1 --first-parent --abbrev=7 --format=%h -- app/frontend', returnStdout: true).trim()
                    echo "app/backend last changed in ${env.BACKEND_VERSION}, app/frontend in ${env.FRONTEND_VERSION}"
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

        stage('Guard: reuse images already in ECR') {
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                container('aws') {
                    script {
                        def images = [
                            [app: 'backend', repo: env.BACKEND_REPO, version: env.BACKEND_VERSION],
                            [app: 'frontend', repo: env.FRONTEND_REPO, version: env.FRONTEND_VERSION],
                        ]
                        def toBuild = []
                        for (image in images) {
                            def found = sh(script: "aws ecr describe-images --repository-name ${image.repo} --image-ids imageTag=${image.version} --region ${AWS_REGION} > /dev/null 2>&1", returnStatus: true)
                            if (found == 0) {
                                echo "${image.app} ${image.version} is already in ECR - reusing it instead of rebuilding."
                            } else {
                                toBuild << "${image.app}:${image.version}"
                            }
                        }
                        // Space-separated app:version pairs - the shell loops below split them.
                        env.TO_BUILD = toBuild.join(' ')
                        env.ALL_IN_ECR = toBuild.isEmpty() ? 'true' : 'false'
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
            when { expression { env.SKIP_BUILD != 'true' && env.ALL_IN_ECR != 'true' } }
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
            when { expression { env.SKIP_BUILD != 'true' && env.ALL_IN_ECR != 'true' } }
            steps {
                echo "Building with BuildKit, to a local file first - nothing reaches ECR before it is scanned"
                container('buildkit') {
                    sh '''
                        for item in ${TO_BUILD}; do
                            app=${item%%:*}
                            buildctl build \
                                --frontend dockerfile.v0 \
                                --local context=app/${app} \
                                --local dockerfile=app/${app} \
                                --output type=docker,name=${item},dest=${WORKSPACE}/${app}.tar
                        done
                    '''
                }
            }
        }

        stage('Scan images for CVEs (Trivy)') {
            when { expression { env.SKIP_BUILD != 'true' && env.ALL_IN_ECR != 'true' } }
            steps {
                echo "Scanning the built files for HIGH/CRITICAL CVEs - fails the build before anything reaches ECR"
                container('trivy') {
                    sh '''
                        for item in ${TO_BUILD}; do
                            trivy image --input ${WORKSPACE}/${item%%:*}.tar \
                                --cache-dir ${WORKSPACE}/.trivy \
                                --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed
                        done
                    '''
                }
            }
        }

        stage('Push to ECR') {
            when { expression { env.SKIP_BUILD != 'true' && env.ALL_IN_ECR != 'true' } }
            steps {
                echo "Pushing the files Trivy scanned to ECR (${env.TO_BUILD}) - a rebuild could differ from what was scanned"
                container('crane') {
                    sh '''
                        export DOCKER_CONFIG=${WORKSPACE}/.docker
                        for item in ${TO_BUILD}; do
                            app=${item%%:*}
                            case ${app} in
                                (backend) repo=${BACKEND_REPO} ;;
                                (frontend) repo=${FRONTEND_REPO} ;;
                            esac
                            crane push ${WORKSPACE}/${app}.tar ${ECR_REGISTRY}/${repo}:${item#*:}
                        done
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

                            BACKEND_LATEST=$(git log -1 --first-parent --abbrev=7 --format=%h -- app/backend)
                            FRONTEND_LATEST=$(git log -1 --first-parent --abbrev=7 --format=%h -- app/frontend)
                            if [ "$BACKEND_LATEST" != "${BACKEND_VERSION}" ] || [ "$FRONTEND_LATEST" != "${FRONTEND_VERSION}" ]; then
                                echo "main already has newer app code (backend ${BACKEND_LATEST}, frontend ${FRONTEND_LATEST}) - that build owns the deploy."
                                exit 0
                            fi

                            cat > ${GITOPS_VALUES_FILE} << YAML
backend:
  image:
    repository: ${ECR_REGISTRY}/${BACKEND_REPO}
    tag: "${BACKEND_VERSION}"

frontend:
  image:
    repository: ${ECR_REGISTRY}/${FRONTEND_REPO}
    tag: "${FRONTEND_VERSION}"
YAML

                            git add ${GITOPS_VALUES_FILE}
                            if git diff --cached --quiet; then
                                echo "${GITOPS_VALUES_FILE} already points at backend ${BACKEND_VERSION}, frontend ${FRONTEND_VERSION} - nothing to deploy."
                                exit 0
                            fi

                            git commit --quiet -m "ci: deploy backend ${BACKEND_VERSION}, frontend ${FRONTEND_VERSION}"

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
            echo "Build ${env.BUILD_NUMBER} finished: backend ${env.BACKEND_VERSION}, frontend ${env.FRONTEND_VERSION}"
        }
        failure {
            echo "Build ${env.BUILD_NUMBER} failed"
        }
    }
}
