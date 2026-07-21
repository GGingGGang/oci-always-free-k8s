#!/usr/bin/env bash
# 기존 app_<service> 유저에게 추가 스키마 GRANT — 유저/비밀번호/k8s Secret은 건드리지 않는다.
# onboard-app-db.sh와 동일 패턴(정적 Pod 매니페스트 + kubectl apply, default NS, mysql:8.0 client)
#
# 용도:
#   1) 서비스가 두 번째 스키마를 추가로 쓰게 될 때 (예: batch 의 Spring Batch 메타 스키마 batch_meta)
#   2) onboard-app-db.sh 로 이미 만든 스키마에 권한을 추가로 부여해야 할 때 (예: DROP/REFERENCES 재부여)
#      — 이 경우 <extra-db>에 기존 DB 이름(예: auth_db)을 그대로 넘기면 됨
#
# onboard-app-db.sh 와 달리 CREATE USER를 하지 않고, 항상 존재하는 유저를 대상으로 GRANT만 실행하므로
# 몇 번을 다시 돌려도 비밀번호/Secret에 영향이 없다.
#
# 사용법:
#   DB_HOST=<heatwave-private-ip> DB_PORT=3306 ./onboard-app-grant.sh <service> <extra-db>
#
# DB_HOST/DB_PORT 확인:
#   terraform -chdir=terraform output -raw heatwave_ip
#   terraform -chdir=terraform output -raw heatwave_port

set -euo pipefail

SERVICE="${1:?사용법: onboard-app-grant.sh <service> <extra-db>}"
EXTRA_DB="${2:?사용법: onboard-app-grant.sh <service> <extra-db>}"
DB_HOST="${DB_HOST:?DB_HOST 필요 (terraform output -raw heatwave_ip)}"
DB_PORT="${DB_PORT:-3306}"

DB_USER="app_${SERVICE}"
# k8s 리소스 이름은 '_'를 못 쓰므로 이름 조립에만 '-'로 치환한 버전을 쓴다 (SQL 쪽 EXTRA_DB는 원본 그대로).
EXTRA_DB_SLUG="$(printf '%s' "${EXTRA_DB}" | tr '_' '-')"
POD_NAME="db-grant-${SERVICE}-${EXTRA_DB_SLUG}"
ADMIN_SECRET="db-grant-${SERVICE}-${EXTRA_DB_SLUG}-admin"
SETUP_NS="default"   # PSA/ambient 영향 없는 NS에서 admin 접속 (onboard-app-db.sh와 동일 패턴)

cleanup() {
  kubectl -n "${SETUP_NS}" delete pod "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${SETUP_NS}" delete secret "${ADMIN_SECRET}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

read -r -s -p "admin password (db_admin_password): " ADMIN_PASSWORD; echo

echo "=== admin 인증용 임시 Secret 생성 (${SETUP_NS}) ==="
kubectl -n "${SETUP_NS}" create secret generic "${ADMIN_SECRET}" \
  --from-literal=password="${ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== ${EXTRA_DB} 생성 + ${DB_USER} GRANT (${DB_HOST}:${DB_PORT}, admin 권한) ==="
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
          mysql -h "${DB_HOST}" -P "${DB_PORT}" -u admin --connect-timeout=10 --ssl-mode=REQUIRED -e "CREATE DATABASE IF NOT EXISTS ${EXTRA_DB}; GRANT CREATE, ALTER, DROP, INDEX, SELECT, INSERT, UPDATE, DELETE, REFERENCES ON ${EXTRA_DB}.* TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
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

unset ADMIN_PASSWORD

echo "완료: ${DB_USER} 가 ${EXTRA_DB} 스키마에 접근 가능. k8s Secret 변경 없음 (기존 db-creds 그대로 재사용)."
