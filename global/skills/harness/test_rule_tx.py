"""rule_tx.py 단위테스트 — 룰 V(select* 안의 쓰기) + 룰 S 회귀.

실행 = python3 -m unittest discover -s <이 디렉터리> -p 'test_*.py'
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rule_tx import (check_java_select_write, check_java_tx_multiwrite,  # noqa: E402
                     filter_by_lines, select_write_enabled)

PATH = "/repo/src/main/java/example/module/foo/service/impl/FooServiceImpl.java"

SRC = """package example.module.foo.service.impl;

@Service("fooService")
public class FooServiceImpl implements FooService {

    public List<Foo> selectFooList(Foo vo) {
        return fooMapper.selectFooList(vo);
    }

    public Foo selectFooView(Foo vo) {
        fooMapper.updateHitCnt(vo);
        return fooMapper.selectFoo(vo);
    }

    public Foo selectFooViaHelper(Foo vo) {
        bumpCount(vo);
        return fooMapper.selectFoo(vo);
    }

    private void bumpCount(Foo vo) {
        logService.insertLog(vo);
    }

    public Foo masterSelectFoo(Foo vo) {
        fooMapper.updateHitCnt(vo);
        return fooMapper.selectFoo(vo);
    }

    // lint-select-write-ok — 의도된 쓰기
    public Foo selectFooMarked(Foo vo) {
        fooMapper.insertTrace(vo);
        return fooMapper.selectFoo(vo);
    }

    public Foo selectFooComment(Foo vo) {
        // fooMapper.updateHitCnt(vo);
        String s = "barMapper.deleteAll(";
        return fooMapper.selectFoo(vo);
    }

    public void insertFoo(Foo vo) {
        fooMapper.insertFoo(vo);
        fooMapper.updateFooCnt(vo);
    }
}
"""


def _line_of(name):
    for idx, line in enumerate(SRC.splitlines(), 1):
        if " %s(" % name in line and "public" in line:
            return idx
    raise AssertionError(name)


class SelectWriteTest(unittest.TestCase):
    def setUp(self):
        self.found = check_java_select_write(PATH, SRC)
        self.names = [msg.split("'")[1] for _, msg, _ in self.found]

    def test_direct_write_in_select_warns(self):
        self.assertIn("selectFooView", self.names)
        msg = [m for _, m, _ in self.found if "'selectFooView'" in m][0]
        self.assertIn("fooMapper.updateHitCnt", msg)
        self.assertIn("masterSelect*", msg)
        self.assertIn(":%d " % _line_of("selectFooView"), msg)

    def test_self_invocation_write_warns(self):
        msg = [m for _, m, _ in self.found if "'selectFooViaHelper'" in m]
        self.assertEqual(1, len(msg))
        self.assertIn("bumpCount→logService.insertLog", msg[0])

    def test_negatives(self):
        for name in ("masterSelectFoo", "selectFooList", "selectFooMarked", "selectFooComment", "insertFoo"):
            self.assertNotIn(name, self.names)

    def test_exact_population(self):
        # 양성은 정확히 두 메서드 — 음성이 새어 들어오거나 양성이 빠지면 깨진다.
        self.assertEqual(["selectFooView", "selectFooViaHelper"], self.names)

    def test_changed_line_scope(self):
        view_line = _line_of("selectFooView")
        self.assertEqual(1, len(filter_by_lines(self.found, set([view_line + 1]))))   # 메서드 안 변경
        self.assertEqual([], filter_by_lines(self.found, set([_line_of("insertFoo")])))  # 밖 변경
        self.assertEqual(2, len(filter_by_lines(self.found, None)))                     # 신규 파일

    def test_class_level_marker_and_non_impl(self):
        marked = SRC.replace("@Service(", "// lint-select-write-ok\n@Service(")
        self.assertEqual([], check_java_select_write(PATH, marked))
        self.assertEqual([], check_java_select_write(PATH.replace("Impl.java", ".java"), SRC))


class RuleSRegressionTest(unittest.TestCase):
    def test_rule_s_unchanged(self):
        found = check_java_tx_multiwrite(PATH, SRC)
        names = [msg.split("'")[1] for _, msg, _ in found]
        # 쓰기 2회 = insertFoo 뿐(masterSelectFoo·selectFooView 는 1회).
        self.assertEqual(["insertFoo"], names)


class EnabledTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _repo(self, name, xml):
        root = os.path.join(self.tmp, name)
        res = os.path.join(root, "src/main/resources/egovframework/spring/com")
        os.makedirs(res)
        if xml is not None:
            with open(os.path.join(res, "context-transaction.xml"), "w") as handle:
                handle.write(xml)
        return root

    def test_always_repo_basename(self):
        self.assertTrue(select_write_enabled(self._repo("__SELECT_WRITE_ALWAYS_REPO__", '<tx:method name="*"/>')))

    def test_sibling_by_xml(self):
        self.assertTrue(select_write_enabled(self._repo(
            "a", '<tx:method name="select*" read-only="true" propagation="REQUIRED"/>')))
        self.assertTrue(select_write_enabled(self._repo("b", '<tx:method name="masterSelect*"/>')))
        self.assertFalse(select_write_enabled(self._repo("c", '<tx:method name="*" propagation="REQUIRED"/>')))
        self.assertFalse(select_write_enabled(self._repo("d", None)))
        # 속성 순서가 뒤집혀도 같은 태그 안이면 양성, 두 속성이 다른 태그에 흩어져 있으면 음성
        self.assertTrue(select_write_enabled(self._repo(
            "e", '<tx:method read-only="true" name="select*"/>')))
        self.assertTrue(select_write_enabled(self._repo(
            "g", '<method read-only="true" name="select*"/>')))  # 기본 네임스페이스(접두사 없음)
        self.assertFalse(select_write_enabled(self._repo(
            "f", '<tx:method name="select*"/><tx:method name="get*" read-only="true"/>')))


class CliTest(unittest.TestCase):
    """마커 없는 레포에서도 룰 V 만 돌고 exit 0(깨진 파일이 섞여도). 파싱 예외 경로는 ScanParseFailTest."""

    def test_markerless_repo_runs_rule_v_only(self):
        tmp = tempfile.mkdtemp()
        try:
            root = os.path.join(tmp, "__SELECT_WRITE_ALWAYS_REPO__")
            pkg = os.path.join(root, "src/main/java/a/service/impl")
            os.makedirs(pkg)
            with open(os.path.join(pkg, "FooServiceImpl.java"), "w") as handle:
                handle.write(SRC)
            with open(os.path.join(pkg, "BrokenServiceImpl.java"), "wb") as handle:
                handle.write(b"public class B { public void selectX( {{{ \xff\xfe")
            proc = subprocess.run(
                [sys.executable, os.path.join(HERE, "check_conventions.py"), "--repo", root],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            out = proc.stdout.decode("utf-8", "replace")
            self.assertEqual(0, proc.returncode, out)
            self.assertIn("룰 V(select* 안의 쓰기)만 실행", out)
            self.assertEqual(2, out.count("[V:읽기전용쓰기]"), out)
            self.assertNotIn("[S:", out)  # 옵트인 룰은 안 돈다
        finally:
            shutil.rmtree(tmp)


class ScanParseFailTest(unittest.TestCase):
    """파일 하나의 파싱 예외는 '파싱 실패로 건너뜀' 경고 1건으로 바뀌고 검사는 계속된다(check_conventions.scan_select_write)."""

    def test_parse_exception_becomes_skip_warning(self):
        import check_conventions
        tmp = tempfile.mkdtemp()
        orig = check_conventions.check_java_select_write
        try:
            pkg = os.path.join(tmp, "src/main/java/a/service/impl")
            os.makedirs(pkg)
            with open(os.path.join(pkg, "FooServiceImpl.java"), "w") as handle:
                handle.write(SRC)

            def boom(path, text):
                raise ValueError("boom")
            check_conventions.check_java_select_write = boom
            scanned, warnings = check_conventions.scan_select_write(tmp, None)
            self.assertEqual(1, scanned)
            self.assertEqual(1, len(warnings), warnings)
            self.assertIn("파싱 실패로 건너뜀(ValueError)", warnings[0])
        finally:
            check_conventions.check_java_select_write = orig
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
