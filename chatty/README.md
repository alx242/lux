### INSTALL

Read the file **INSTALL.md** or view it online on
[GitHub](https://github.com/hawk/lux/blob/euc/chatty/INSTALL.md).

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
    erl -pa ../../chatty/ebin -sname cons -s chatty client mytopic
    erl -pa ../../chatty/ebin -sname hawk -s chatty client mytopic

### Walkthru
    cd lux/chatty/test/intro
    async_startup.lux
    sync_startup.lux
    cleanup.lux

### Post mortem analysis
  - Textual
    - Suite
        - Summary log
    - Case
        - Stdin log
        - Stdout log
        - Event log
        - Extra logs
        - TAP
        - JUnit
  - Annotated
    - HTML
    - Statistics

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
  - Skip and skip unless
  - Unstable and unstable unless
  - History of test runs
      - Overview
      - Per architecture
      - Per host
      - Still failing test cases
  - build and test
      - Use --list-dir
      - Use make

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

### patterns
  - Match on prompts
  - Match on trace output
  - Match on poll style printout
  - Match on permutations
  - Regexp vs verbatim
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
  - Generate documentation
      - Markdown
        - From example runs
        - From built-in debugger help
  - Delux test cases

### Lessons learned
  - Expect like testing requires a different mindset
  - Testability is a vital property of products
  - Effective post mortem analysis of test runs is a big time saver
  - Test cases (as well as test tools) does also needs to be debugged

### More info

github.com/hawk/lux (Apache license)

See the file **../lux.html** for the full documentation or view it online
on [GitHub](https://github.com/hawk/lux/blob/euc/doc/lux.md).
