
pipeline {
    agent any

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
                script {
                    def account = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
                    env.ECR_REGISTRY = "${account}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                    echo "ECR registry: ${env.ECR_REGISTRY}"
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

        stage('Validate the chart and its alert rules') {
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                script {
                    echo "Rendering the chart and checking its PromQL - a bad expression fails here instead of at sync time"
                    sh '''
                        helm lint ${CHART_DIR} --set-string ${CHART_STUB_VALUES}
                        helm template check ${CHART_DIR} --set-string ${CHART_STUB_VALUES} > /tmp/rendered.yaml
                        helm template check ${CHART_DIR} --set-string ${CHART_STUB_VALUES}                             -s templates/prometheusrule.yaml                             | sed -n '/^spec:/,$p' | tail -n +2 | sed 's/^  //' > /tmp/rules.yaml
                        promtool check rules /tmp/rules.yaml
                    '''
                }
            }
        }

        stage('Build Docker Images') {
            when { expression { env.SKIP_BUILD != 'true' && env.IMAGE_EXISTS != 'true' } }
            steps {
                script {
                    echo "Building Docker images with tag: ${env.VERSION}"
                    sh '''
                        docker build -t ${BACKEND_REPO}:${VERSION} ./app/backend
                        docker build -t ${FRONTEND_REPO}:${VERSION} ./app/frontend
                    '''
                }
            }
        }

        stage('Scan Images for CVEs (Trivy)') {
            when { expression { env.SKIP_BUILD != 'true' && env.IMAGE_EXISTS != 'true' } }
            steps {
                script {
                    echo "Scanning images for HIGH/CRITICAL CVEs - fails the build before anything reaches ECR"
                    sh '''
                        trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed ${BACKEND_REPO}:${VERSION}
                        trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed ${FRONTEND_REPO}:${VERSION}
                    '''
                }
            }
        }

        stage('Login to AWS ECR') {
            when { expression { env.SKIP_BUILD != 'true' && env.IMAGE_EXISTS != 'true' } }
            steps {
                script {
                    echo "Logging in to AWS ECR"
                    sh '''
                        aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                    '''
                }
            }
        }

        stage('Push to ECR') {
            when { expression { env.SKIP_BUILD != 'true' && env.IMAGE_EXISTS != 'true' } }
            steps {
                script {
                    echo "Pushing images to ECR with tag: ${env.VERSION}"
                    sh '''
                        docker tag ${BACKEND_REPO}:${VERSION} ${ECR_REGISTRY}/${BACKEND_REPO}:${VERSION}
                        docker push ${ECR_REGISTRY}/${BACKEND_REPO}:${VERSION}

                        docker tag ${FRONTEND_REPO}:${VERSION} ${ECR_REGISTRY}/${FRONTEND_REPO}:${VERSION}
                        docker push ${ECR_REGISTRY}/${FRONTEND_REPO}:${VERSION}
                    '''
                }
            }
        }

        stage('Update GitOps Values') {
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                script {
                    echo "Bumping ${GITOPS_VALUES_FILE} to ${env.VERSION} and pushing - this is what triggers ArgoCD to deploy"
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
# Managed by Jenkins CI - do not hand-edit. ArgoCD deploys whatever tag is here.
backend:
  image:
    tag: "${VERSION}"
frontend:
  image:
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
    }

    post {
        success {
            echo "Pipeline executed successfully!"
            echo "Backend image: ${ECR_REGISTRY}/${BACKEND_REPO}:${VERSION}"
            echo "Frontend image: ${ECR_REGISTRY}/${FRONTEND_REPO}:${VERSION}"
            echo "ArgoCD will pick up the values-images.yaml change and deploy it automatically."
        }
        failure {
            echo "Pipeline failed. Check logs for details."
        }
    }
}
