pipeline {
    agent any

    environment {
        AWS_REGION = 'us-east-1'
        ECR_REGISTRY = '123456789.dkr.ecr.us-east-1.amazonaws.com'
        BACKEND_REPO = 'devops-task-manager-backend'
        FRONTEND_REPO = 'devops-task-manager-frontend'
        BUILD_TAG = "${BUILD_NUMBER}-${new Date().format('yyyyMMddHHmmss')}"
        AWS_CREDENTIALS = credentials('aws-credentials')
        EKS_CLUSTER_NAME = 'task-manager-cluster'
        KUBECONFIG = "${WORKSPACE}/kubeconfig"
    }

    parameters {
        string(name: 'AWS_ACCOUNT_ID', defaultValue: '123456789', description: 'AWS Account ID')
        string(name: 'AWS_REGION', defaultValue: 'us-east-1', description: 'AWS Region')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                echo "Repository checked out successfully"
            }
        }

        stage('Build Docker Images') {
            steps {
                script {
                    echo "Building Docker images with tag: ${BUILD_TAG}"
                    sh '''
                        docker build -t ${BACKEND_REPO}:${BUILD_TAG} ./backend
                        docker build -t ${FRONTEND_REPO}:${BUILD_TAG} ./frontend
                        docker tag ${BACKEND_REPO}:${BUILD_TAG} ${BACKEND_REPO}:latest
                        docker tag ${FRONTEND_REPO}:${BUILD_TAG} ${FRONTEND_REPO}:latest
                    '''
                }
            }
        }

        stage('Login to AWS ECR') {
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
            steps {
                script {
                    echo "Pushing images to ECR"
                    sh '''
                        docker tag ${BACKEND_REPO}:${BUILD_TAG} ${ECR_REGISTRY}/${BACKEND_REPO}:${BUILD_TAG}
                        docker tag ${BACKEND_REPO}:latest ${ECR_REGISTRY}/${BACKEND_REPO}:latest
                        docker push ${ECR_REGISTRY}/${BACKEND_REPO}:${BUILD_TAG}
                        docker push ${ECR_REGISTRY}/${BACKEND_REPO}:latest

                        docker tag ${FRONTEND_REPO}:${BUILD_TAG} ${ECR_REGISTRY}/${FRONTEND_REPO}:${BUILD_TAG}
                        docker tag ${FRONTEND_REPO}:latest ${ECR_REGISTRY}/${FRONTEND_REPO}:latest
                        docker push ${ECR_REGISTRY}/${FRONTEND_REPO}:${BUILD_TAG}
                        docker push ${ECR_REGISTRY}/${FRONTEND_REPO}:latest
                    '''
                }
            }
        }

        stage('Configure kubectl') {
            steps {
                script {
                    echo "Configuring kubectl for EKS"
                    sh '''
                        aws eks update-kubeconfig --region ${AWS_REGION} --name ${EKS_CLUSTER_NAME} --kubeconfig ${KUBECONFIG}
                        export KUBECONFIG=${KUBECONFIG}
                        kubectl cluster-info
                    '''
                }
            }
        }

        stage('Update Kubernetes Manifests') {
            steps {
                script {
                    echo "Updating Kubernetes manifests with new image tags"
                    sh '''
                        export ECR_BACKEND_IMAGE=${ECR_REGISTRY}/${BACKEND_REPO}:${BUILD_TAG}
                        export ECR_FRONTEND_IMAGE=${ECR_REGISTRY}/${FRONTEND_REPO}:${BUILD_TAG}

                        sed -i "s|backend:latest|${ECR_BACKEND_IMAGE}|g" k8s/backend-deploy.yaml
                        sed -i "s|frontend:latest|${ECR_FRONTEND_IMAGE}|g" k8s/frontend-deploy.yaml
                    '''
                }
            }
        }

        stage('Deploy to EKS') {
            steps {
                script {
                    echo "Deploying to EKS cluster"
                    sh '''
                        export KUBECONFIG=${KUBECONFIG}

                        kubectl apply -f k8s/configmap.yaml

                        # Create secret from AWS Secrets Manager (or use local secret for local deployments)
                        if aws secretsmanager get-secret-value --secret-id app-secrets --region ${AWS_REGION} 2>/dev/null; then
                            echo "Using secrets from AWS Secrets Manager"
                            SECRETS=$(aws secretsmanager get-secret-value --secret-id app-secrets --region ${AWS_REGION} --query SecretString --output text)
                            DB_USER=$(echo $SECRETS | jq -r '.DB_USER')
                            DB_PASSWORD=$(echo $SECRETS | jq -r '.DB_PASSWORD')
                            kubectl create secret generic app-secret --from-literal=DB_USER="$DB_USER" --from-literal=DB_PASSWORD="$DB_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -
                        else
                            echo "AWS Secrets Manager not configured, using local secret"
                            kubectl apply -f k8s/secret.yaml
                        fi

                        kubectl apply -f k8s/postgress-pvc.yaml
                        kubectl apply -f k8s/postgres-db.yaml
                        kubectl apply -f k8s/backend-deploy.yaml
                        kubectl apply -f k8s/frontend-deploy.yaml
                        kubectl apply -f k8s/ingress.yaml

                        echo "Waiting for deployments to roll out..."
                        kubectl rollout status deployment/backend-deploy -n default --timeout=5m
                        kubectl rollout status deployment/frontend-deploy -n default --timeout=5m
                        kubectl rollout status deployment/postgres-deploy -n default --timeout=5m
                    '''
                }
            }
        }

        stage('Verify Deployment') {
            steps {
                script {
                    echo "Verifying deployment status"
                    sh '''
                        export KUBECONFIG=${KUBECONFIG}

                        echo "=== Pod Status ==="
                        kubectl get pods -o wide

                        echo "=== Service Status ==="
                        kubectl get svc

                        echo "=== Ingress Status ==="
                        kubectl get ingress

                        echo "=== Deployment Status ==="
                        kubectl get deployment
                    '''
                }
            }
        }
    }

    post {
        always {
            script {
                sh '''
                    docker logout ${ECR_REGISTRY} || true
                '''
            }
        }
        success {
            echo "Pipeline executed successfully!"
            echo "Backend image: ${ECR_REGISTRY}/${BACKEND_REPO}:${BUILD_TAG}"
            echo "Frontend image: ${ECR_REGISTRY}/${FRONTEND_REPO}:${BUILD_TAG}"
        }
        failure {
            echo "Pipeline failed. Check logs for details."
        }
    }
}
