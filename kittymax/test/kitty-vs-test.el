;;; kitty-vs-test.el --- C# and C as Visual Studio did them  -*- lexical-binding: t; -*-

;; Build errors, solutions, tests at point, the MSVC environment,
;; compile_commands.json from MSBuild's evaluation, CMake presets.
;;   emacs --batch -L lisp -L lisp/lang -l test/kitty-vs-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-data-dir kitty-cache-dir)
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'kitty-csharp)
(require 'kitty-msvc)
(require 'kitty-c)

;;;; Build errors

(defun kvt--match (line)
  "(FILE LINE COL TYPE) the MSBuild regexp reads from LINE, or nil."
  (when (string-match kitty-msbuild-error-regexp line)
    (list (match-string 1 line) (match-string 2 line) (match-string 3 line)
          (cond ((match-string 4 line) 'warning) ((match-string 5 line) 'info) (t 'error)))))

(ert-deftest kitty-vs-msbuild-errors ()
  "dotnet build's and cl.exe's error lines (taken from real output) are jumps."
  ;; dotnet build on Linux, a path with a space (real output)
  (should (equal '("/tmp/cs/My App/Program.cs" "5" "36" error)
                 (kvt--match "/tmp/cs/My App/Program.cs(5,36): error CS1002: ; expected [/tmp/cs/My App/MyApp.csproj]")))
  (should (equal '("/tmp/cs/My App/Program.cs" "5" "27" warning)
                 (kvt--match "/tmp/cs/My App/Program.cs(5,27): warning CS8602: Dereference of a possibly null reference. [/x.csproj]")))
  ;; Windows: indented, a drive letter, spaces
  (should (equal '("C:\\Users\\me\\source\\repos\\My App\\Program.cs" "12" "5" error)
                 (kvt--match "    C:\\Users\\me\\source\\repos\\My App\\Program.cs(12,5): error CS0103: The name 'x' does not exist [C:\\a.csproj]")))
  ;; cl.exe through MSBuild -m: a node prefix, a line without a column
  (should (equal '("C:\\src\\lib\\util.c" "10" nil error)
                 (kvt--match "2>C:\\src\\lib\\util.c(10): error C2143: syntax error: missing ';' before '}'")))
  (should (equal '("C:\\src\\main.c" "3" "1" error)
                 (kvt--match "C:\\src\\main.c(3,1): fatal error C1083: Cannot open include file: 'x.h'")))
  (should (equal '("src\\a.c" "7" "9" info)
                 (kvt--match "src\\a.c(7,9): message : see declaration of 'f'")))
  (should-not (kvt--match "LINK : fatal error LNK1104: cannot open file 'x.exe'"))
  (should-not (kvt--match "  Determining projects to restore...")))

(ert-deftest kitty-vs-msbuild-errors-in-compilation-mode ()
  "In a *compilation* buffer, RET on the warning lands on its line and column."
  (let* ((dir (kvt--tree '(("My App/Program.cs" . "a\nb\nc\nd\n        string? s = null; s.Length;\n"))))
         (file (expand-file-name "My App/Program.cs" dir)))
    (with-current-buffer (get-buffer-create "*kvt compilation*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s(5,27): warning CS8602: Dereference [x.csproj]\n" file)))
      (setq default-directory dir)
      (compilation-mode)
      (goto-char (point-min))
      (let ((msg (progn (compilation--ensure-parse (point-max))
                        (get-text-property (point) 'compilation-message))))
        (should msg)
        (should (= 1 (compilation--message->type msg))))
      (compile-goto-error)
      (should (equal file (buffer-file-name)))
      (should (= 5 (line-number-at-pos)))
      (should (= 26 (current-column)))
      (kill-buffer))))

(ert-deftest kitty-vs-dotnet-test-stack-frames ()
  "A failing test's stack frame jumps to its line."
  (let ((line "   at App.Tests.MathTests.Adds() in C:\\src\\App.Tests\\MathTests.cs:line 14"))
    (should (string-match kitty-dotnet-test-trace-regexp line))
    (should (equal "C:\\src\\App.Tests\\MathTests.cs" (match-string 1 line)))
    (should (equal "14" (match-string 2 line)))))

;;;; Solutions

(defconst kvt--sln "
Microsoft Visual Studio Solution File, Format Version 12.00
Project(\"{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}\") = \"App\", \"src\\App\\App.csproj\", \"{1}\"
EndProject
Project(\"{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}\") = \"engine\", \"native\\engine\\engine.vcxproj\", \"{2}\"
EndProject
Project(\"{2150E333-8FDC-42A3-9474-1A3956D46DE8}\") = \"Solution Items\", \"Solution Items\", \"{3}\"
EndProject
")

(defun kvt--tree (files)
  "A temporary directory holding FILES (an alist of name and contents)."
  (let ((dir (file-name-as-directory (make-temp-file "kvt" t))))
    (dolist (f files)
      (let ((path (expand-file-name (car f) dir)))
        (make-directory (file-name-directory path) t)
        (with-temp-file path (insert (cdr f)))))
    dir))

(ert-deftest kitty-vs-solution-projects ()
  ".sln and .slnx list their projects; folders are not projects."
  (let ((dir (kvt--tree `(("All.sln" . ,kvt--sln)
                          ("New.slnx" . "<Solution>\n  <Project Path=\"src/App/App.csproj\" />\n  <Folder Name=\"/x/\" />\n</Solution>\n")
                          ("src/App/App.csproj" . "<Project/>")
                          ("src/App/Program.cs" . "class P {}")))))
    (should (equal (list (expand-file-name "src/App/App.csproj" dir) (expand-file-name "native/engine/engine.vcxproj" dir))
                   (kitty-solution-projects (expand-file-name "All.sln" dir))))
    (should (equal (list (expand-file-name "src/App/App.csproj" dir))
                   (kitty-solution-projects (expand-file-name "New.slnx" dir))))
    (let ((default-directory (expand-file-name "src/App/" dir)))
      (should (equal (expand-file-name "All.sln" dir) (kitty-csharp-solution)))
      (should (equal (expand-file-name "src/App/App.csproj" dir) (kitty-csharp-project))))
    ;; MSVC: the solution with a .vcxproj in it
    (let ((default-directory (expand-file-name "src/App/" dir)))
      (should (equal (expand-file-name "All.sln" dir) (kitty-msvc-solution))))))

(ert-deftest kitty-vs-build-command ()
  "SPC m m builds the solution, quietly, with errors once."
  (let ((dir (kvt--tree `(("All.sln" . ,kvt--sln) ("src/App/Program.cs" . "class P {}"))))
        command env)
    (cl-letf (((symbol-function 'compile)
               (lambda (cmd &rest _) (setq command cmd env compilation-environment))))
      (let ((default-directory (expand-file-name "src/App/" dir)))
        (kitty-csharp-build)))
    (should (equal (mapconcat #'shell-quote-argument
                              (list "dotnet" "build" (expand-file-name "All.sln" dir) "-nologo" "-clp:NoSummary" "-c" "Debug")
                              " ")
                   command))
    (should (member "MSBUILDTERMINALLOGGER=off" env))))

;;;; Tests at point

(defconst kvt--test-file "namespace App.Tests;

public class MathTests
{
    [Fact]
    public void Adds()
    {
        Assert.Equal(4, 2 + 2);|
    }
}
")

(ert-deftest kitty-vs-test-name-at-point ()
  "The test under the cursor: Namespace.Class.Method (file-scoped namespace)."
  (with-temp-buffer
    (insert (string-replace "|" "" kvt--test-file))
    (goto-char (point-min))
    (search-forward "2 + 2")
    (should (equal "App.Tests.MathTests.Adds" (kitty-csharp-test-name)))
    (should (equal "App.Tests.MathTests" (kitty-csharp-test-name t)))))

(ert-deftest kitty-vs-test-name-tree-sitter ()
  "With the C# grammar, nested classes and block namespaces too."
  (skip-unless (and (fboundp 'treesit-language-available-p) (treesit-language-available-p 'c-sharp)))
  (with-temp-buffer
    (insert "namespace A.B {\n class Outer {\n  class Inner {\n   [Test] public void T1() { var x = 1; }\n  }\n }\n}\n")
    (csharp-ts-mode)
    (goto-char (point-min)) (search-forward "var x")
    (should (equal "A.B.Outer.Inner.T1" (kitty-csharp-test-name)))))

(ert-deftest kitty-vs-test-filter ()
  "SPC m t runs dotnet test on the project with the test's filter."
  (let ((dir (kvt--tree `(("All.sln" . ,kvt--sln) ("tests/T.csproj" . "<Project/>")
                          ("tests/MathTests.cs" . ,(string-replace "|" "" kvt--test-file)))))
        command)
    (with-current-buffer (let ((auto-mode-alist nil)) (find-file-noselect (expand-file-name "tests/MathTests.cs" dir)))
      (search-forward "2 + 2")
      (cl-letf (((symbol-function 'compile) (lambda (cmd &rest _) (setq command cmd))))
        (kitty-csharp-test-at-point))
      (kill-buffer))
    (should (string-match-p "\\`dotnet test .*T\\.csproj -nologo -c Debug --filter FullyQualifiedName\\\\?~App.Tests.MathTests.Adds\\'"
                            command))))

;;;; MSVC

(ert-deftest kitty-vs-msvc-env-parsing ()
  "The output of `set' after vcvarsall.bat becomes the environment."
  (let ((env (kitty-msvc-parse-env "INCLUDE=C:\\VC\\include;C:\\SDK\\ucrt\r\nPath=C:\\VC\\bin;C:\\Windows\r\nVCToolsVersion=14.44.35207\r\nODD=a=b\r\n")))
    (should (equal "C:\\VC\\include;C:\\SDK\\ucrt" (cdr (assoc "INCLUDE" env))))
    (should (equal "a=b" (cdr (assoc "ODD" env))))
    (should (equal "C:\\VC\\bin;C:\\Windows" (cdr (assoc-string "PATH" env t))))))

(defconst kvt--evaluation
  ;; The shape `msbuild x.vcxproj -getItem:ClCompile -getProperty:...' prints
  ;; (checked against dotnet msbuild), with Windows paths.
  "{
  \"Properties\": {
    \"IncludePath\": \"C:\\\\VC\\\\include;C:\\\\SDK\\\\ucrt;\",
    \"ExternalIncludePath\": \"\",
    \"TargetPath\": \"C:\\\\src\\\\engine\\\\x64\\\\Debug\\\\engine.exe\",
    \"ConfigurationType\": \"Application\"
  },
  \"Items\": {
    \"ClCompile\": [
      { \"Identity\": \"src\\\\main.c\", \"FullPath\": \"C:\\\\src\\\\engine\\\\src\\\\main.c\",
        \"AdditionalIncludeDirectories\": \"C:\\\\src\\\\engine\\\\include;\",
        \"PreprocessorDefinitions\": \"_DEBUG;_CONSOLE;\", \"LanguageStandard_C\": \"stdc17\",
        \"ForcedIncludeFiles\": \"pch.h\", \"AdditionalOptions\": \"/utf-8 %(AdditionalOptions)\" },
      { \"Identity\": \"src\\\\old.c\", \"FullPath\": \"C:\\\\src\\\\engine\\\\src\\\\old.c\", \"ExcludedFromBuild\": \"true\" },
      { \"Identity\": \"src\\\\glue.cpp\", \"FullPath\": \"C:\\\\src\\\\engine\\\\src\\\\glue.cpp\",
        \"LanguageStandard\": \"stdcpp20\", \"PreprocessorDefinitions\": \"%(PreprocessorDefinitions)\" }
    ]
  }
}")

(ert-deftest kitty-vs-compile-commands-from-evaluation ()
  "Each ClCompile becomes a cl.exe command clangd understands; excluded files are left out."
  (let* ((eval (json-parse-string kvt--evaluation :object-type 'plist :null-object nil :false-object nil))
         (entries (kitty-msvc-compile-commands eval "C:/src/engine/engine.vcxproj")))
    (should (= 2 (length entries)))
    (should (equal ["cl.exe" "/nologo" "/c" "/std:c17" "/D_DEBUG" "/D_CONSOLE" "/IC:\\src\\engine\\include"
                    "/imsvcC:\\VC\\include" "/imsvcC:\\SDK\\ucrt" "/FIpch.h" "/utf-8" "%(AdditionalOptions)"
                    "C:\\src\\engine\\src\\main.c"]
                   (plist-get (car entries) :arguments)))
    (should (equal "C:/src/engine" (plist-get (car entries) :directory)))
    (should (equal "/std:c++20" (aref (plist-get (cadr entries) :arguments) 3)))))

(ert-deftest kitty-vs-compile-commands-through-real-msbuild ()
  "MSBuild's evaluation, read back from a real msbuild (dotnet msbuild here)."
  (skip-unless (executable-find "dotnet"))
  (let* ((dir (kvt--tree '(("eng.vcxproj" . "<Project xmlns=\"http://schemas.microsoft.com/developer/msbuild/2003\">
  <PropertyGroup><IncludePath>C:\\VC\\include</IncludePath><ConfigurationType>Application</ConfigurationType>
    <TargetPath>$(MSBuildProjectDirectory)\\bin\\$(Configuration)\\eng.exe</TargetPath></PropertyGroup>
  <ItemDefinitionGroup Condition=\"'$(Configuration)|$(Platform)'=='Debug|x64'\">
    <ClCompile><AdditionalIncludeDirectories>$(MSBuildProjectDirectory)\\include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
      <PreprocessorDefinitions>_DEBUG;%(PreprocessorDefinitions)</PreprocessorDefinitions></ClCompile>
  </ItemDefinitionGroup>
  <ItemGroup><ClCompile Include=\"main.c\" /></ItemGroup>
  <Target Name=\"Build\" />
</Project>")
                           ("main.c" . "int main(void) { return 0; }\n")
                           ("All.sln" . "Project(\"{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}\") = \"eng\", \"eng.vcxproj\", \"{2}\"\nEndProject\n"))))
         (wrapper (expand-file-name "msbuild" dir)))
    (with-temp-file wrapper (insert "#!/bin/sh\nexec dotnet msbuild \"$@\"\n"))
    (set-file-modes wrapper #o755)
    (cl-letf (((symbol-function 'kitty-msvc-msbuild) (lambda () wrapper)))
      (let ((out (kitty-msvc-write-compile-commands (expand-file-name "All.sln" dir))))
        (let ((entries (json-parse-string (with-temp-buffer (insert-file-contents out) (buffer-string))
                                          :object-type 'plist)))
          (should (= 1 (length entries)))
          (let ((args (append (plist-get (aref entries 0) :arguments) nil)))
            (should (member "/D_DEBUG" args))
            (should (member (concat "/I" (expand-file-name "include" (directory-file-name dir))) args))
            (should (member "/imsvcC:\\VC\\include" args))
            (should (equal (expand-file-name "main.c" dir) (car (last args))))))))))

;;;; CMake presets, single files

(ert-deftest kitty-vs-cmake-preset-binary-dir ()
  "A preset's build directory: inherited, with its macros expanded."
  (let ((presets '((:name "base" :hidden t :binaryDir "${sourceDir}/out/build/${presetName}")
                   (:name "x64-debug" :inherits "base")
                   (:name "env" :binaryDir "$env{KVT_BUILD}/b"))))
    (should (equal "/src/app/out/build/x64-debug" (kitty-c-preset-binary-dir "x64-debug" presets "/src/app/")))
    (let ((process-environment (cons "KVT_BUILD=/tmp/kvt" process-environment)))
      (should (equal "/tmp/kvt/b" (kitty-c-preset-binary-dir "env" presets "/src/app/"))))
    (should-not (kitty-c-preset-binary-dir "none" presets "/src/app/"))))

(ert-deftest kitty-vs-single-file-commands ()
  "One file alone, with my-nvim's flags for gcc and for cl."
  (let ((cmd (kitty-c-compile-file-command "/src/a.c" nil "gcc")))
    (should (string-match-p "\\`gcc -std\\\\?=c23 -Wall -Wextra -g /src/a.c -o .*/c-bin/a-[0-9a-f]\\{8\\}" cmd)))
  (let ((cmd (kitty-c-compile-file-command "C:/src/a.c" nil "cl")))
    (should (string-match-p "\\`cl /nologo /std\\\\?:clatest /W4 /Zi /EHsc C\\\\?:/src/a.c /Fe\\\\?:" cmd))))

(ert-deftest kitty-vs-build-system-order ()
  "CMake first, then a Visual Studio solution, then make."
  (let ((dir (kvt--tree '(("Makefile" . "all:\n") ("eng.vcxproj" . "<Project/>") ("a.c" . "")))))
    (let ((default-directory dir))
      (cl-letf (((symbol-function 'kitty-project-root) (lambda () dir)))
        (should (eq 'msbuild (kitty-c--build-system)))
        (with-temp-file (expand-file-name "CMakeLists.txt" dir) (insert "project(x)\n"))
        (should (eq 'cmake (kitty-c--build-system)))))))

(provide 'kitty-vs-test)
;;; kitty-vs-test.el ends here
