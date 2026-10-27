// tb_common.svh -- pass/fail bookkeeping shared by all testbenches

int    n_pass = 0;
string cur_test = "";

task automatic test_begin(input string name);
    cur_test = name;
endtask

task automatic test_fail(input string why);
    $display("[FAIL] %s: %s", cur_test, why);
    $fatal(1, "test '%s' failed", cur_test);
endtask

task automatic test_pass();
    $display("[PASS] %s", cur_test);
    n_pass++;
endtask

task automatic test_summary(input string tb_name);
    $display("--------------------------------------------");
    $display("%s: %0d tests, %0d passed, 0 failed", tb_name, n_pass, n_pass);
    $display("--------------------------------------------");
endtask
