// CI only: build, scan with Trivy, push to ECR, bump the image tag in
// values-images.yaml and push it back. ArgoCD (see
// gitops/argocd-application.yaml) watches this repo and deploys the app.
// The guard stage below skips the pipeline when the last commit was made
// by this same pipeline (jenkins-ci-bot), to avoid a loop.

pipeline {
    agent any

    environment {
        AWS_REGION = 'us-east-1'
        BACKEND_REPO = 'devops-task-manager-backend'
        FRONTEND_REPO = 'devops-task-manager-frontend'
        VERSION = "1.0.${BUILD_NUMBER}"
        GITOPS_VALUES_FILE = 'gitops/task-manager/values-images.yaml'
        GITOPS_REPO_URL = 'github.com/Ben-Sh7/aws-eks-cicd-pipeline.git'
        CI_BOT_NAME = 'jenkins-ci-bot'
        CI_BOT_EMAIL = 'jenkins-ci-bot@users.noreply.github.com'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                echo "Repository checked out successfully"
            }
        }

        // ECR_REGISTRY is resolved here rather than hardcoded: it embeds the
        // AWS account id, so a literal value silently breaks every deployment
        // into a different account (push denied, then ImagePullBackOff).
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
                    env.SKIP_BUILD = (lastAuthor == env.CI_BOT_NAME) ? 'true' : 'false'
                    if (env.SKIP_BUILD == 'true') {
                        echo "Last commit was by ${env.CI_BOT_NAME} - skipping to avoid a loop."
                    }
                }
            }
        }

        stage('Build Docker Images') {
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                script {
                    echo "Building Docker images with tag: ${VERSION}"
                    sh '''
                        docker build -t ${BACKEND_REPO}:${VERSION} ./app/backend
                        docker build -t ${FRONTEND_REPO}:${VERSION} ./app/frontend
                        docker tag ${BACKEND_REPO}:${VERSION} ${BACKEND_REPO}:latest
                        docker tag ${BACKEND_REPO}:${VERSION} ${BACKEND_REPO}:v1
                        docker tag ${FRONTEND_REPO}:${VERSION} ${FRONTEND_REPO}:latest
                        docker tag ${FRONTEND_REPO}:${VERSION} ${FRONTEND_REPO}:v1
                    '''
                }
            }
        }

        stage('Scan Images for CVEs (Trivy)') {
            when { expression { env.SKIP_BUILD != 'true' } }
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
            when { expression { env.SKIP_BUILD != 'true' } }
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
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                script {
                    echo "Pushing images to ECR with tags: ${VERSION}, latest, v1"
                    sh '''
                        docker tag ${BACKEND_REPO}:${VERSION} ${ECR_REGISTRY}/${BACKEND_REPO}:${VERSION}
                        docker tag ${BACKEND_REPO}:latest ${ECR_REGISTRY}/${BACKEND_REPO}:latest
                        docker tag ${BACKEND_REPO}:v1 ${ECR_REGISTRY}/${BACKEND_REPO}:v1
                        docker push ${ECR_REGISTRY}/${BACKEND_REPO}:${VERSION}
                        docker push ${ECR_REGISTRY}/${BACKEND_REPO}:latest
                        docker push ${ECR_REGISTRY}/${BACKEND_REPO}:v1

                        docker tag ${FRONTEND_REPO}:${VERSION} ${ECR_REGISTRY}/${FRONTEND_REPO}:${VERSION}
                        docker tag ${FRONTEND_REPO}:latest ${ECR_REGISTRY}/${FRONTEND_REPO}:latest
                        docker tag ${FRONTEND_REPO}:v1 ${ECR_REGISTRY}/${FRONTEND_REPO}:v1
                        docker push ${ECR_REGISTRY}/${FRONTEND_REPO}:${VERSION}
                        docker push ${ECR_REGISTRY}/${FRONTEND_REPO}:latest
                        docker push ${ECR_REGISTRY}/${FRONTEND_REPO}:v1
                    '''
                }
            }
        }

        stage('Update GitOps Values') {
            when { expression { env.SKIP_BUILD != 'true' } }
            steps {
                script {
                    echo "Bumping ${GITOPS_VALUES_FILE} to ${VERSION} and pushing - this is what triggers ArgoCD to deploy"
                    withCredentials([usernamePassword(credentialsId: 'github-credentials', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
                        sh '''
                            cat > ${GITOPS_VALUES_FILE} << YAML
# Managed by Jenkins CI - do not hand-edit. ArgoCD deploys whatever tag is here.
backend:
  image:
    tag: "${VERSION}"
frontend:
  image:
    tag: "${VERSION}"
YAML

                            git config user.name "${CI_BOT_NAME}"
                            git config user.email "${CI_BOT_EMAIL}"
                            git add ${GITOPS_VALUES_FILE}
                            git commit -m "ci: deploy ${VERSION}"
                            git push https://${GIT_USER}:${GIT_TOKEN}@${GITOPS_REPO_URL} HEAD:main
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
            echo "Tags: ${VERSION}, latest, v1"
            echo "ArgoCD will pick up the values-images.yaml change and deploy it automatically."
        }
        failure {
            echo "Pipeline failed. Check logs for details."
        }
    }
}
