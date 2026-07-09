#!/usr/bin/env bash
# 신규 서비스 DB 온보딩 — app_<service> 유저/DB 생성 + k8s Secret 등록
# db-smoketest.yaml과 동일한 패턴(정적 Pod 매니페스트 + kubectl apply, default NS, mysql:8.0 client)
# 수동 Secret 패턴 (Vault Database secrets engine 이관 전까지 임시)
#
# 사용법:
#   DB_HOST=<heatwave-private-ip> DB_PORT=3306 ./onboard-app-db.sh <service> <namespace>
#
# DB_HOST/DB_PORT 확인:
#   terraform -chdir=terraform output -raw heatwave_ip
#   terraform -chdir=terraform output -raw heatwave_port

set -euo pipefail

SERVICE="${1:?사용법: onboard-app-db.sh <service> <namespace>}"
NAMESPACE="${2:?사용법: onboard-app-db.sh <service> <namespace>}"
DB_HOST="${DB_HOST:?DB_HOST 필요 (terraform output -raw heatwave_ip)}"
DB_PORT="${DB_PORT:-3306}"

DB_NAME="${SERVICE}_db"
DB_USER="app_${SERVICE}"
SECRET_NAME="db-creds"
POD_NAME="db-onboard-${SERVICE}"
ADMIN_SECRET="db-onboard-${SERVICE}-admin"
SETUP_NS="default"   # PSA/ambient 영향 없는 NS에서 admin 접속 (namespace 인자와 별개, db-smoketest와 동일 패턴)

cleanup() {
  kubectl -n "${SETUP_NS}" delete pod "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${SETUP_NS}" delete secret "${ADMIN_SECRET}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

read -r -s -p "admin password (db_admin_password): " ADMIN_PASSWORD; echo
read -r -s -p "${DB_USER} 비밀번호 (미입력시 랜덤 생성): " APP_PASSWORD; echo
if [ -z "${APP_PASSWORD}" ]; then
  APP_PASSWORD="$(openssl rand -base64 24)"
  echo "비밀번호 랜덤 생성됨 — k8s Secret에 저장되니 별도로 적어둘 필요는 없음."
fi

echo "=== admin 인증용 임시 Secret 생성 (${SETUP_NS}) ==="
kubectl -n "${SETUP_NS}" create secret generic "${ADMIN_SECRET}" \
  --from-literal=password="${ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== ${DB_NAME} / ${DB_USER} 생성 (${DB_HOST}:${DB_PORT}, admin 권한) ==="
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${SETUP_NS}
  labels:
    app.kubernetes.io/name: ${POD_NAME}
    app.kubernetes.io/component: database-onboarding
    app.kubernetes.io/managed-by: manual
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: mysql-client
      image: docker.io/mysql:8.0
      command: ["sh", "-c"]
      args:
        - |
          mysql -h "${DB_HOST}" -P "${DB_PORT}" -u admin --connect-timeout=10 --ssl-mode=REQUIRED -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME}; CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${APP_PASSWORD}'; GRANT CREATE, ALTER, INDEX, SELECT, INSERT, UPDATE, DELETE ON ${DB_NAME}.* TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
      env:
        - name: MYSQL_PWD
          valueFrom:
            secretKeyRef:
              name: ${ADMIN_SECRET}
              key: password
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          memory: 128Mi
YAML

echo "=== 완료 대기 ==="
if ! kubectl -n "${SETUP_NS}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD_NAME}" --timeout=60s; then
  echo "실패 — 로그:"
  kubectl -n "${SETUP_NS}" logs "${POD_NAME}" || true
  exit 1
fi
kubectl -n "${SETUP_NS}" logs "${POD_NAME}"

echo "=== k8s Secret ${NAMESPACE}/${SECRET_NAME} 생성 ==="
kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=username="${DB_USER}" \
  --from-literal=password="${APP_PASSWORD}" \
  --from-literal=database="${DB_NAME}" \
  --from-literal=host="${DB_HOST}" \
  --from-literal=port="${DB_PORT}" \
  --dry-run=client -o yaml | kubectl apply -f -

unset ADMIN_PASSWORD APP_PASSWORD

echo "완료: ${NAMESPACE}/${SECRET_NAME} (keys: username/password/database/host/port)"
echo "이관 대상 목록(Vault Database secrets engine)에 ${DB_USER} 추가 필요"
