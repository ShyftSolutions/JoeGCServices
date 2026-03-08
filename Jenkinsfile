// Example Jenkinsfile for a project using SonarQube + Trivy
// Add this to the root of your GitHub repository

pipeline {
    agent any

    triggers {
        // Poll GitHub for changes every 2 minutes (no webhook needed)
        pollSCM('H/2 * * * *')
    }

    environment {
        SONAR_SCANNER_HOME = tool name: 'SonarQubeScanner', type: 'hudson.plugins.sonar.SonarRunnerInstallation'
        SONAR_PROJECT_KEY = "${JOB_NAME}".replaceAll('/', '_').replaceAll(' ', '_')
        IMAGE_NAME = "${JOB_NAME}".replaceAll('/', '-').replaceAll('%2F', '-').replaceAll(' ', '-').toLowerCase()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('SonarQube Analysis') {
            when {
                branch 'main'  // Community Edition: single branch only
            }
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh """
                        ${SONAR_SCANNER_HOME}/bin/sonar-scanner \
                            -Dsonar.projectKey=\${SONAR_PROJECT_KEY} \
                            -Dsonar.sources=. \
                            -Dsonar.exclusions=dependency-check-report.* \
                            -Dsonar.host.url=http://sic-sonarqube:9000
                    """
                }
            }
        }

        stage('SonarQube Quality Gate') {
            when {
                branch 'main'
            }
            steps {
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Trivy Filesystem Scan') {
            steps {
                sh '''
                    trivy filesystem --severity CRITICAL \
                        --exit-code 1 \
                        --format table \
                        .
                '''
            }
        }

        stage('OWASP Dependency-Check') {
            environment {
                DC_HOME = tool name: 'DependencyCheck', type: 'org.jenkinsci.plugins.DependencyCheck.tools.DependencyCheckInstallation'
                NVD_API_KEY = credentials('nvd-api-key')
            }
            steps {
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    sh '''
                        "$DC_HOME"/bin/dependency-check.sh \
                            --scan . \
                            --out . \
                            --format HTML \
                            --format JSON \
                            --failOnCVSS 7 \
                            --disableAssembly \
                            --disableNodeAudit \
                            --exclude "**/*.tar" \
                            --nvdApiKey "$NVD_API_KEY"
                    '''
                }
                archiveArtifacts artifacts: 'dependency-check-report.*', allowEmptyArchive: true
            }
        }

        stage('Build Image') {
            steps {
                sh 'podman build -t ${IMAGE_NAME}:${BUILD_NUMBER} -f web/Dockerfile web/'
            }
        }

        stage('Trivy Image Scan') {
            steps {
                sh """
                    podman save ${IMAGE_NAME}:${BUILD_NUMBER} -o image.tar
                    trivy image --input image.tar \
                        --severity HIGH,CRITICAL \
                        --exit-code 1 \
                        --format table
                    rm -f image.tar
                """
            }
        }
    }

    post {
        always {
            sh "podman rmi ${IMAGE_NAME}:${BUILD_NUMBER} || true"
            cleanWs()
        }
        failure {
            echo 'Pipeline failed. Check SonarQube and Trivy reports.'
        }
    }
}
