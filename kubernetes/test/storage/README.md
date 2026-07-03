# Storage Infrastructure (Block Volume CSI)

오라클 클라우드(OCI)의 Block Volume CSI 드라이버와 StorageClass(`oci-bv`)가 정상적으로 프로비저닝 및 마운트되는지 검증하기 위한 스모크 테스트 가이드입니다.

## 1. 전제 조건
- OKE 클러스터에 OCI Block Volume CSI 드라이버가 설치되어 있어야 합니다.
- `oci-bv` 명칭의 StorageClass가 사전 등록되어 있어야 합니다.

## 2. 스모크 테스트 매니페스트 (`csi-smoketest.yaml`)
테스트에 사용된 PVC 및 Pod 매니페스트 통합본입니다.

## 3. 검증 명령어 및 실행 결과 예시 (Smoke Test)

> 아래 출력은 특정 시점 1회 실행 예시다 — 현재 클러스터 상태를 나타내지 않는다. 재현하려면 §2 매니페스트를 직접 apply 해서 확인.

### ① 테스트 자원 배포
StorageClass를 통해 50Gi 자원을 동적 프로비저닝(Dynamic Provisioning)하고, 이를 마운트할 Pod를 생성합니다.

`$ kubectl apply -f csi-smoketest.yaml`

```bash
persistentvolumeclaim/csi-smoketest created
pod/csi-smoketest created
```

### ② PVC 프로비저닝 및 Bound 상태 확인

OCI Block Volume이 정상적으로 생성되어 클러스터 내 볼륨(csi-3c14c77a-...)으로 바인딩되었는지 확인합니다.

`$ kubectl get pvc csi-smoketest`
```bash
NAME            STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
csi-smoketest   Bound    csi-3c14c77a-3237-4ab0-8125-a2f5432b87c4   50Gi       RWO            oci-bv         1m
```

### ③ Pod 상태 및 볼륨 Attach 모니터링
Pod가 생성되면서 OCI 인스턴스에 블록 볼륨이 물리적으로 맵핑(Attach)되고 컨테이너가 정상 구동되는지 확인합니다.

`$ kubectl get pod csi-smoketest -w`
```
NAME            READY   STATUS    RESTARTS   AGE
csi-smoketest   1/1     Running   0          46s
```

### ④ 데이터 입출력(I/O) 및 마운트 최종 검증
볼륨이 마운트된 내부 경로(/data)에 데이터가 정상적으로 저장되고 읽히는지 이진 검증을 수행합니다

```
$ kubectl exec csi-smoketest -- cat /data/hello
csi-smoketest ok
```

## 4. 결론 

스토리지 동적 할당: 정상 (Bound 완료)

볼륨 인스턴스 부착(Attach): 정상 (ContainerCreating -> Running 전환 확인)

파일 시스템 Read/Write: 정상 (csi-smoketest ok 반환 확인)

## 5. 정리

50Gi PVC 는 Always Free Block Volume 한도를 소비한다. 검증 후 방치하면 Vault/Prometheus 몫을 잠식하므로 즉시 삭제:

```bash
kubectl delete -f csi-smoketest.yaml
kubectl get pvc csi-smoketest   # NotFound 확인
```

PVC 삭제 후에도 OCI 콘솔에 Block Volume 이 잔존하면 (StorageClass `reclaimPolicy` 확인 후) 수동 삭제.