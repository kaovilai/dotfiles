source zsh/functions/git-utils.zsh
mkdir -p .testdir/foo .testdir/bar .testdir/baz
cd .testdir

time (exec-dirs-ds-echo "f*" ds main testcmd "echo hello")
time (exec-dirs-ds-echo "b*" ds main testcmd "echo hello")

cd ..
rm -rf .testdir
