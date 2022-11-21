
# infoflow

<img alt="logo" src="media/logo.png" width="200" />

experimental multiarch dynamic binary analysis

\[more information coming soon™\]

## overview

infoflow is an experimental framework for **opaque binary optimization via dynamic analysis**.

by observing the behavior of a program at runtime at the architectural level, we can **fully analyze its computation graph** and provide a suite of optimizations and introspection.

infoflow's flagship algorithm is **InfoFlow IFT**, which traces the flow of abstract information through a program to fully describe how any value in the cpu registers or memory was computed, with its value history and dependency graph. this dependency graph also allows us to optimize how the value is computed on the architectural level.

infoflow is designed to be as **architecture-agnostic** as possible, to maximize where it can be applied. this is accomplished with flexible abstractions to avoid duplicating logic but also retain the ability to make specializations to a particular architecture when needed.

## cite

```
@misc{redthing2022infoflow,
      title={Experimental Multiarch Dynamic Binary Analysis},
      author={redthing1},
      year={2022},
}
```
