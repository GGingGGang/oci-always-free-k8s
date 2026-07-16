# NLB Smoke Test

OCI Network LB가 OKE 클러스터에 정상 프로비저닝되는지 검증.
Istio 설치 *전* 에 NLB annotation 자체의 동작을 격리해서 확인하는 목적.

확인 항목:

- OCI Cloud Controller Manager (CCM) 가 `oci.oraclecloud.com/load-balancer-type=nlb` annotation 을 인식하는지
- NLB가 public subnet에 정상 생성되는지
- NSG / Security List 가 80 포트를 허용하는지
- backend pod 까지 트래픽이 도달하는지

## 1. 전제 조건

- OKE 클러스터 도달 가능 (`kubectl get nodes` OK)
- OCI Always Free 는 NLB 1개 무료 — 평소 누적된 NLB 가 없는지 OCI 콘솔에서 확인 후 실행 권장

## 2. 설치 (테스트 자원 배포)

```bash
kubectl apply -f nlb-smoketest.yaml
```

```bash
deployment.apps/nlb-smoketest created
service/nlb-smoketest created
```

## 3. 검증

1. pod Running 확인.

   `kubectl get pod -l app.kubernetes.io/name=nlb-smoketest`

   ```bash
   NAME                             READY   STATUS    RESTARTS   AGE
   nlb-smoketest-xxxxxxxxxx-yyyyy   1/1     Running   0          30s
   ```

2. NLB 프로비저닝 (1-2분 소요). `EXTERNAL-IP` 컬럼에 public IP 떠야 함.

   `kubectl get svc nlb-smoketest -w`

   ```bash
   NAME            TYPE           CLUSTER-IP      EXTERNAL-IP       PORT(S)        AGE
   nlb-smoketest   LoadBalancer   10.96.123.45    <pending>         80:30000/TCP   10s
   nlb-smoketest   LoadBalancer   10.96.123.45    140.xxx.xxx.xxx   80:30000/TCP   90s
   ```

3. HTTP 응답 확인 (200 OK + nginx welcome 페이지). 핵심은 status code 200, 응답 body 는 nginx 기본 페이지.

   `NLB_IP=$(kubectl get svc nlb-smoketest -o jsonpath='{.status.loadBalancer.ingress[0].ip}')`

   `curl -v http://$NLB_IP/`

   ```bash
   < HTTP/1.1 200 OK
   < Server: nginx/1.27.x
   < Content-Type: text/html
   ...
   <html>
   <head><title>Welcome to nginx!</title></head>
   ...
   ```

4. OCI 콘솔에서 NLB 인스턴스 직접 확인 (선택). Networking → Load Balancers → Network Load Balancers.

## 4. 결정

### Istio Gateway annotation 과의 차이

| annotation | smoketest | Istio gateway.yaml |
|------------|:---------:|:------------------:|
| `load-balancer-type: nlb` | ✅ | ✅ |
| `oci-network-load-balancer-shape: flexible` | ✅ | ✅ |
| `oci-network-load-balancer-is-preserve-source: true` | ❌ | ✅ |

**`preserve-source` 제외 사유**: 이 옵션은 NLB → backend 구간에 PROXY protocol 을 enable. 일반 webserver (nginx, http-echo 등) 는 PROXY protocol parser 가 기본 없음 → request 가 mangled 됨. 본 smoketest 는 NLB 프로비저닝 + L4 전달까지만 확인하고, PROXY protocol 동작 검증은 Istio envoy 가 backend 가 되는 시점에 envoy 가 처리.

### backend 이미지

`docker.io/nginxinc/nginx-unprivileged:1.27-alpine` (multi-arch amd64/arm64).

두 가지 함정 회피 박혀 있음:
- ARM64 호환: OCI Always Free 의 메인 컴퓨트는 Ampere A1 (ARM64). amd64-only 이미지는 `ImageInspectError` 발생. multi-arch manifest 확인은 `docker manifest inspect <image>` 로 사전 점검.
- FQDN 명시: OKE 노드의 containerd 가 `short-name-mode=enforcing` 으로 잡혀 있어 `nginxinc/...` 같은 short name 은 거부 (`returns ambiguous list`). 모든 이미지에 registry prefix (`docker.io/`, `ghcr.io/`, `registry.k8s.io/`, etc.) 명시 필수.

## 5. 주의 사항

### 실패 시 점검

| 증상 | 원인 후보 |
|------|-----------|
| `EXTERNAL-IP` 가 `<pending>` 으로 멈춤 | CCM 이 NLB 생성 못 함. `kubectl describe svc nlb-smoketest` 의 Events 확인. 흔한 원인: subnet/CCM 권한 부족, NSG 미생성, IAM policy 부족 |
| `EXTERNAL-IP` 떴는데 curl timeout | NSG/SecList 가 80 포트 ingress 막힘. terraform `nsg_public_id` 의 ingress rule 확인 |
| `Connection refused` | backend pod 가 unhealthy. `kubectl logs -l app.kubernetes.io/name=nlb-smoketest` |
| 응답이 깨져서 옴 | preserve-source 켠 채로 PROXY protocol 미지원 backend. 본 smoketest 에는 해당 없음 |
| pod 가 `ImageInspectError` / `ErrImagePull` | 이미지가 amd64-only manifest. OCI A1 (ARM64) 노드에서 platform mismatch. multi-arch 이미지로 교체 필요. `kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}'` 로 노드 아키텍처 확인 |
| `short name mode is enforcing ... returns ambiguous list` | OKE containerd 가 short image name 거부. registry prefix 명시 (`docker.io/<org>/<image>`, `ghcr.io/<org>/<image>` 등) |

### 정리

NLB 는 떠 있는 한 OCI 콘솔에 누적. 검증 끝나면 즉시 삭제.

```bash
kubectl delete -f nlb-smoketest.yaml
```

```bash
deployment.apps "nlb-smoketest" deleted
service "nlb-smoketest" deleted
```
