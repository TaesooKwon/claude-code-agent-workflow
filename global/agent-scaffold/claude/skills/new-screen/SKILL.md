---
name: new-screen
description: 신규 화면/기능 착수 표준 절차 + CRUD 스캐폴드 생성기(eGov/Spring Boot 2.7 + Maven 멀티모듈 + MyBatis + Thymeleaf). 신규 목록/등록/수정 화면, 새 도메인 테이블 기반 기능 개발을 시작할 때 사용. 트리거="새 화면", "신규 기능", "CRUD 만들어", "관리 화면 추가", "스캐폴드".
---

# new-screen — 신규 화면 착수 체크리스트 + CRUD 스캐폴드

신규 화면 개발의 표준 진입로. **체크리스트(순서 고정) → 생성기(Core+BO 골격) → 웹 레이어 미러링 → 검증 → 기록**.

> ⚠️ **이식 사본 — 부트스트랩 재추출 필수.** 이 스킬은 이식용 스캐폴드에서 온 사본이다.
> `scaffold_crud.py` 상단 REEXTRACT 구간(모듈 디렉터리·소스 레이아웃·공통 유틸·JS 네임스페이스)과
> `templates/*.tmpl`의 `{{...}}` 플레이스홀더를 **대상 레포 실측으로 채워야** 동작한다(미치환 시
> `_guard_reextract()`가 기동 차단). 정본 참조 도메인(Core 최신형 / BO 웹레이어 / FO)도 이 레포의
> 실제 최신형 화면으로 확정해 아래 참조부를 갱신한다.

## 0. 착수 체크리스트 (건너뛰기 금지)

1. **유사 화면 회상**: "이거 기존 어느 화면과 같은가?"를 먼저 확정 — memory 회상 + 유사 도메인 실파일 확인. 구조·모달·JS는 그대로 재사용, 차이는 데이터/모델만.
2. **설계서와 어긋나는 자리는 컨펌 먼저**: 다르게 만들 지점·설계서에 정의가 없는 자리는 구현 전 **"설계서 / 제안 / 이유" 3칸 표**로 컨펌받는다. 기본값 = **설계서 그대로**. ([[figma-deviation-confirm-first]]) 컨펌 표를 쓰기 전에 설계서가 비었거나 갈리는 자리를 **확인 질문 체크리스트**로 훑는다 — 예외 상황(0건·실패·중복 제출)·에러 처리·입력검증(허용목록)·경합 자원 여부(경합 자원이면 락·유니크·재검증)·권한/스코프·기존 화면·공유 자산 영향·하위호환. 설계가 갈리는 자리는 **"최소 변경 / 정석" 2안 + 추천 1개**로 낸다(모든 자리에 2안을 만들지 않는다). (출처: 공식 feature-dev, 2026-11-04 흡수)
3. **시나리오 되읽기(컨펌본)**: 사용자 결정(D 목록)마다 Given/When/Then 1~3줄로 되읽어 컨펌받고 설계서 `§시나리오(컨펌본)` 절에 둔다 — 경계·경로("어느 경로로 들어와도 X 가 있다")를 문장에 박는다. 설계서와 코드가 일치하는 오해는 리뷰·테스트·E2E 가 못 잡는다(정본 = 전역 규약 "사양 되읽기"). 신규 CRUD 면 여기서 **엔티티 필드 전수 소유권 표**(`화면이 정함/서버가 강제/저장값 유지`, 등록·수정 별도)도 함께 컨펌받는다. **기존 화면 개편**이면 되읽기 전에 **현행 규칙 카드**를 먼저 뽑는다 — 규칙마다 구체 값이 든 Given/When/Then + 근거 `파일:라인` + 확신(높음/중간/낮음) + 사용자에게 물을 것. 확신 낮음은 컨펌 질문으로 올린다. (출처: 공식 code-modernization business-rules-extractor, 2026-11-04 흡수)
4. **스키마 선검증**:
   - 기존 테이블이면: 스냅샷 확인(`.claude/schema-snapshot.json` 직접 조회). 오래됐으면 갱신 — `python3 .claude/scripts/export_schema_snapshot.py`.
   - 새 테이블이면: DB 표준명명 적용 → DDL 초안 → dev DB 적용 → **스냅샷 갱신 의무**.
5. **스캐폴드 생성**(아래 1절) — Core 8파일(+`--admin`이면 BO 5파일).
6. **웹 레이어 마감**: BO 그리드 컬럼·모달 필드는 생성 골격의 TODO 마커를 채우고, FO는 이 레포 최신형 FO 화면 구조를 미러링(생성기 미지원 — 아래 3절 함정 참조).
7. **연결 등록**: 메뉴(화면 경유 등록), 시큐리티 화이트리스트(FO 비로그인 접근 시), 템플릿 `@{}` 링크.
8. **검증**: `harness`(계약+컨벤션+룰K+컴파일) → 화면검증(`e2e-verify`/`playwright-verify`). 전량 회귀는 **커밋 게이트가 아니라 온디맨드** — 새 테이블·설정·공통모듈이 걸린 무거운 변경이면 **제안**하고 승인 시 실행.
9. **기록**: memory + `docs/agent_history.md` 2채널.

## 1. CRUD 스캐폴드 생성기

```bash
python3 .claude/skills/new-screen/scaffold_crud.py \
  --table tn_xxx --domain Xxx --module <module> --pkg <pkg> \
  [--admin] [--pk <컬럼>] [--uuid-prefix <축약>] [--dry-run] [--force]
```

- 입력 = `.claude/schema-snapshot.json`(테이블·컬럼·코멘트·PK). 산출 = Core 8파일(PaXxxSrch/PaXxx/RsXxx·entity·Mapper·Service·ServiceImpl·매퍼XML), `--admin` 시 +BO 5파일(MngXxxController·xxxIndex/xxxInsert.html·xxxIndex/xxxReg.js).
- **PK/타입 처리(반영 완료)**: ①문자 UUID PK(varchar≥접두어+33) = 서비스단 채번 + 길이검증(초과 시 중단) ②수치 SN PK = 하우스 관례 MAX+1(`read<Domain>NextSn` selectKey) 채번 — 전역 `foundation-check` C5 가 금지하는 방식이라 **동시 등록이 없는 관리 테이블에만** 쓰고, 경합 자원(신청·정원 등)은 UUID PK 로 만든다. 동시 등록이 겹치면 PK 중복으로 저장이 실패한다 ③`decimal(p,0) p>9`·`bigint` = Java `Long`(Integer 오버플로 회피) ④민감컬럼(`*_pswd/*_pwd/*_salt/*_token`) = 목록 응답·SELECT·그리드에서 제외(입력/상세엔 유지) ⑤감사 결손 테이블 = 미사용 변수/구문 가드. → **이 5종은 생성기에 반영됨(무결 케이스).** 단 `del_yn` 없는 테이블은 소프트 딜리트 불가로 명확히 중단(스캐폴드 대상 아님).
- 기존 파일은 **덮어쓰지 않음**(충돌 시 중단·`--force`만 예외). `--dry-run`으로 경로 선확인.
- 생성 코드는 레포 게이트(계약검사·룰 A~H·K·Java8) 무결 통과가 계약 — 위반이 나오면 생성기 버그로 취급하고 수정.

## 2. 하우스 패턴 핵심 (생성물 이해용)

- **DTO 이원**: `Pa*`=요청(검증 @Valid·`toEntity()`/`fromEntity()`), `Rs*`=목록 응답(조인 파생 포함). 상세 조회 반환은 엔티티.
- **PK 채번**: DB 자동증가 아님 — ServiceImpl `create`에서 UUID 유틸(`{{UUID_UTIL_NAME}}.getUUID("<접두>")`) 또는 MAX+1, create는 생성 PK(String) 반환.
- **감사값 주입 = 컨트롤러 단일 경로**: Pa DTO에 감사필드 두지 않는다. 컨트롤러 헬퍼(`getUniqId()`→`getId()`→`"SYSTEM"` 폴백)로 엔티티에 set.
- **페이징 이원(의도된 규약)**: BO(.json 목록)=`setPagination(search)`+PaginationInfo / FO(SSR)=`(currentPage-1)*PAGE_SIZE` 수동 역산. ⚠️ `DefaultSearchVO.firstIndex` 기본값 1 — FO에서 그대로 쓰면 첫 행 누락.
- **XML**: 별칭 `a` 고정, `<sql id="whereXxxList">` 공유(목록+카운트), 상세 SELECT는 `AS camelCase` 명시, 비교연산자 CDATA, 소프트딜리트 `DEL_YN='Y'`.
- **URL**: BO=`readXxx.do`/`readXxxList.json`(read 접두 강제) / FO 화면 세그먼트 `list.do`/`view.do`는 팀 승인 예외(메서드·매퍼 id는 여전히 read 접두).

## 3. 함정 (실측)

- `@Mapper`는 `org.apache.ibatis.annotations.Mapper`(신형) — eGov 구형(`org.egovframe.rte...`) 혼재하나 신규 금지.
- `javax.validation`(스프링부트 2.7) — jakarta 금지.
- ServiceImpl: `EgovAbstractServiceImpl` 상속 금지(구형), `@Service("xxxService")` 빈명 명시 + 쓰기 메서드 `@Transactional`.
- FO 상세 PK 파라미터 타입: UUID 문자열 PK면 String(대부분), `SN` 수치 PK만 Long.
- 구세대 화면(create void 반환·Pa 상세조회 등)을 참조 소스로 쓰지 말 것 — 정본은 위 2절.
- 생성 후 반드시 `--changed-only` 게이트 먼저(컴파일보다 빠른 피드백), 이후 스코프 컴파일.
- **프론트 공통 JS 네임스페이스**(`{{JS_NS}}.alert`/`.paging`/`.requestFetch` 등)와 UUID 유틸은 부트스트랩 재추출 값 — 대상 레포 공통 유틸명으로 확정.
- **라이브 리전**: 비동기 검색의 **0건·실패 박스엔 `role="status"`**. 단 `role="status"` 는 **값이 같아도 재대입되면 재낭독**되므로 `if(el.textContent !== String(v))` 로 **바뀔 때만** 대입한다. 입력 중 갱신되는 자리엔 달지 않는다(결과 확정 시점에만 통지).
- **경합 자원 도메인**(신청·정원·채번 등)은 생성 골격 위에 트랜잭션 정밀 설계를 별도 적용 — 스캐폴드는 단순 CRUD 계약까지만.
