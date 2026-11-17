# 판정 위치 — eGov Boot / Spring Boot + Thymeleaf (+ fetch 공통 래퍼)

판별 신호: 어느 pom 이든 `org.egovframe.boot`(eGov Boot starter parent) 또는 `spring-boot`. 멀티모듈(`<modules>`)이 흔하다 — 모듈마다 같은 공통 JS·설정이 **복제**돼 있는지부터 본다.

| 계열 | 어디를 보나 | 확인 명령·방법 |
|---|---|---|
| C1 | 공통 요청 래퍼(js 공통 파일의 fetch 래퍼)·fetch 인터셉터(로딩 표시) | 래퍼 함수를 끝까지 읽고 8결말 각각의 분기·콜백 인자를 표로 적는다. 래퍼가 동기 구간(본문 변환)에서 던질 수 있는지, 성공 콜백 예외를 어디로 보내는지까지. 호출부 수 = `grep -rc '<래퍼명>(' <js 경로>` |
| C2 | `@ControllerAdvice`·`@ExceptionHandler`, `ErrorController` 구현 여부, `templates/error.html`·`error/4xx.html`, `server.error.*` | `grep -rn 'getMessage()' --include='*Controller.java'` 로 응답에 예외 문구를 싣는 형태를 센다 · 없는 URL·강제 500 을 실요청해 화면 확인 |
| C3 | 템플릿 `th:utext` 사용처 · Jackson `ObjectMapper`/`CharacterEscapes` 커스터마이즈(WebMvcConfig 류) · 입력 XSS 필터(RequestWrapper) · `CharacterEncodingFilter` 순서 · datasource URL 의 문자셋과 커넥션 초기화 SQL | `grep -rn 'th:utext'` · `grep -rn 'CharacterEscapes\|setCharacterEscapes'` · 이모지 왕복 1회 |
| C4 | `SecurityConfig`(permitAll 목록·기본 규칙) · 인증 정본(세션 속성 vs JWT 쿠키) · 세션 쿠키 이름(모듈별) · 유휴 타이머·keep-alive 엔드포인트 · 프로파일별 서명키 | 기본 규칙이 `anyRequest().authenticated()`/deny 인지 · 토큰만으로 인증이 서는 경로가 있는지 |
| C5 | 트랜잭션 설정 Java config 의 `AspectJExpressionPointcut` 표현식 · `@Transactional` 사용 규약 · 채번 SQL | 포인트컷 패키지 vs 자체 서비스 구현 패키지 대조: `git ls-files \| grep -c '<자체패키지경로>/.*Impl\.java$'` 와 `@Transactional` 보유 수 비교 |
| C6 | 매퍼 UPDATE 의 WHERE(삭제 여부 조건) · `<set>` 동적 SQL · DTO 기본값 · 업로드 상한(`spring.servlet.multipart.*`)과 화면 안내 문구 | 매퍼 SQL 렌더 테스트(`getBoundSql().getSql()`)로 조건 단언 |
| C7 | 공통 파일 컨트롤러·서비스(업로드·다운로드·삭제), 다운로드 URL 의 인가 | 비로그인으로 다운로드 URL 직접 호출 |

※ 공통 JS 가 퍼블(디자인팀) 소유라 수정 금지인 레포가 있다 — 그때 C1 수리는 개발 소유 래퍼 쪽에서 한다.
