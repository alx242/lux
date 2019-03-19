### INSTALL

Read the file **INSTALL.md** or view it online on
[GitHub](https://github.com/hawk/lux/blob/euc/tutorial/chatty/INSTALL.md) about
how to do a local install of LUX, build and test the chatty app.

### Tail-f/Cisco
  - ConfD
    - Model driven configuration management framework for a network element
    - Render nortbound interfaces such as CLI, Netconf, SNMP, Rest, RestConf
    - Tracable internal interfaces
  - NSO
    - Orchestrator for a massive number of (hetrogenous) network elements
    - Same standardised nortbound interfaces as Confd
    - Standard interfaces southbound combined with
    - 100+ adaptors for network elements lacking standard interfaces

### How do we test a simple chat server?
    cd lux/chatty/test/intro
    erl -pa ../../chatty/ebin -sname mytopic -s chatty server
    erl -pa ../../chatty/ebin -sname cons    -s chatty client mytopic
    erl -pa ../../chatty/ebin -sname hawk    -s chatty client mytopic

### Walkthru the test cases and emphasize on their differences
    cd lux/chatty/test/intro
    async_startup_fail.lux
    sync_startup.lux
    sync_startup_cleanup.lux

### Post mortem analysis
  - Walkthru the different logs
    - Test suite
      - Annotated summary log (HTML)
      - Summary log
      - Config log
    - Test case
      - Annotated event log (HTML)
      - Shell stdin log(s)
      - Shell stdout log(s)
      - Event log
      - Extra logs
      - Config log
      - Statistics
      - TAP log
      - JUnit log

### Debugging
  - Use stdin logs
    - Create shells manually
    - Copy and paste from stdin log
  - Use built-in debugger
      lux -d cleanup.lux
      help
      c 30
      shell cons
      !im().
      n
      help quit
      c

### Infra structure support
  - Architecture/host dependent config
    - uname -sm
    - multiplier
    - timeout
  - Skip and skip unless
  - Unstable and unstable unless
  - Build and test
    - Walkthru lux/chatty/test/Makefile
  - Jenkins
    - Automated tests
  - History of test runs
    - Overview
    - Per architecture
    - Per host
    - Still failing test cases

### More concepts
  - Fail pattern
  - Loops
    - Foreach
    - Break pattern
  - Macros
  - Variable scope
    - Environment
      - Initial values
      - Require
      - Local within one shell
      - Global for all shells
      - Statement block (my)
      - Sub expression
  - Shell config
    - Pseudo terminal (PTY)
    - Normalized prompt
    - Using other types of shells
  - Using LUX as an all purpose scripting language

### Patterns
  - Match on prompts
  - Check command status
  - Match on trace output
  - Match on poll style printout
  - Match on permutations
  - Regexp match vs verbatim match
  - Use the power of various interactive languages

### Implementation
  - Why is Erlang a good fit?
    - Concurrency
    - Port programs
    - Built-in regular expresssions (re)
    - Timers

### Maintenance of LUX itself
  - Run LUX in Erlang debugger
  - Use Erlang trace
    - Interactive display
    - Display filtered Erlang trace
  - Use Event Tracer
  - Use xref
  - Use reltool
  - Install as stand-alone incl Erlang runtime
  - Documentation
    - Markdown
    - Generated from example runs
    - Generated from built-in debugger help
    - Generated from .md.src files
  - Test of LUX itsel

### Lessons learned
  - Expect like testing requires a different mindset
  - Testability is a vital property of products
  - Effective post mortem analysis of test runs is a big time saver
  - Test cases (as well as test tools) does also needs to be debugged

### More info

  - Download from https://github.com/hawk/lux (Apache license)

See the file **../lux.html** for the full documentation or view it online
on [GitHub](https://github.com/hawk/lux/blob/euc/doc/lux.md).
