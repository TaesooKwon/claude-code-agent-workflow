# 판정 위치 — eGovFrame 3.x + Spring 4.x + JSP (+ jQuery $.ajax)

판별 신호: `egovframework.rte.version` 3.x · `<packaging>war` · 대개 단일 모듈(`<modules>` 없음). 설정은 XML(`WEB-INF/config/**`, `src/main/resources/egovframework/spring/*.xml`)에 있다.

| 계열 | 어디를 보나 | 확인 명령·방법 |
|---|---|---|
| C1 | 전역 핸들러 `$(document).ajaxError`·`$.ajaxSetup`(벤더 jquery 파일 제외) · 공통 ajax 래퍼(있어도 호출처가 0일 수 있다) · raw `$.ajax(` 호출 수와 `error:` 보유 비율 | `grep -rE '\$\.ajax\(' <webapp> --include='*.jsp' --include='*.js'`(jquery·min·lib 경로 제외)로 호출처를 센다. raw 호출이 수백이면 **레버는 래퍼가 아니라 전역 `ajaxError`/`ajaxSetup` 도입**(세션 만료 응답·비JSON 오류 본문을 한 곳에서 처리) |
| C2 | `web.xml` `<error-page>`(400·403·exception-type 포함 여부) · `SimpleMappingExceptionResolver`(servlet xml — `defaultErrorView`·`exceptionMappings`·`statusCodes`) · 오류 JSP 가 예외·스택을 출력하나 | resolver 에 `statusCodes`/`defaultStatusCode` 가 없으면 AJAX 요청도 200 + HTML 오류 뷰를 받을 수 있다(실요청으로 확인) |
| C3 | JSP EL `${}` 는 **기본 이스케이프가 없다** — `<c:out>`/`fn:escapeXml` 사용 비율 · `escapeXml="false"` 줄 · `defaultHtmlEscape` 설정 · `<%=` 스크립틀릿 출력 · `${param.` 직접 출력 · 입력 쪽 XSS 인터셉터/필터 | `grep -c '<c:out'` vs 태그 밖 `${` 수(근사 — `<script>` 안·컨텍스트 경로 변수가 섞이니 경계를 적는다) · `grep -rn 'escapeXml="false"'` · `grep -rn '\${param\.'` |
| C4 | 인가 인터셉터(`egov-com-interceptor.xml` 류)의 판정 축(역할인가 등급 정수인가) · `.do` 외 경로가 통제 밖인가 · 메뉴 숨김만으로 막는 화면 · 다건 처리 루프의 인증 확인 위치 | 메뉴에 없는 화면 URL 을 권한 없는 계정으로 직타 |
| C5 | `context-transaction.xml` 의 `aop:pointcut` 표현식 vs 자체 `*Impl` 패키지 | `find . -name '*Impl.java'` 경로를 표현식 패키지와 대조(자체 패키지가 `egovframework.*` 밖이면 미커버) |
| C6 | 매퍼 UPDATE 의 삭제 여부 조건 · 목록 저장(전체 해제 = 빈 목록) 서버 처리 · 하드 DELETE 의 참조 테이블 정리 | `grep -rn 'BETWEEN #{'` 로 datetime 날짜 경계 점검(부록 SQL 관례) |
| C7 | 공통 파일 업로드·다운로드 컨트롤러(eGov `EgovFileDownloadController` 류)의 인가·경로 검증 | 비로그인 직접 다운로드 호출 |

※ 운영 부록: 로컬 기동 블로커(서블릿 컨테이너 클래스로더·외부 SSO 홈 경로·포트 리터럴)와 `~/.m2` 의 eGov 스텁 POM(정상 저장소 고정 필요)은 이 스택에서 첫날 막히는 단골이다.
