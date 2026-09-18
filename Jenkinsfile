pipeline {
    agent none

    parameters {
        choice(
            name: 'OS_FILTER',
            choices: ['all', 'linux', 'linux-arm', 'macosx', 'win64'],
            description: 'Build all platforms or one native platform'
        )
    }

    options {
        buildDiscarder(logRotator(daysToKeepStr: '120', numToKeepStr: '150'))
        timestamps()
        timeout(time: 180, unit: 'MINUTES')
    }

    stages {
        stage('Build') {
            matrix {
                agent { label "${PLATFORM}" }
                when {
                    beforeAgent true
                    anyOf {
                        expression { params.OS_FILTER == 'all' }
                        expression { params.OS_FILTER == env.PLATFORM }
                    }
                }
                axes {
                    axis {
                        name 'PLATFORM'
                        values 'linux', 'linux-arm', 'macosx', 'win64'
                    }
                }
                options { skipDefaultCheckout true }
                stages {
                    stage('Checkout') {
                        steps {
                            cleanWs()
                            checkout scm
                        }
                    }
                    stage('Compile and package') {
                        steps {
                            script {
                                if (isUnix()) {
                                    sh "./scripts/build-posix.sh '${PLATFORM}'"
                                } else {
                                    powershell './scripts/build-windows.ps1'
                                }
                            }
                        }
                    }
                }
                post {
                    always {
                        archiveArtifacts artifacts: 'artifacts/gdb_*.zip', allowEmptyArchive: true, fingerprint: true
                    }
                }
            }
        }
    }
}
