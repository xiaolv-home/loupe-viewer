#!/usr/bin/env python3
"""示例模块"""
import os

@dataclass
class Point:
    x: int = 0  # 横坐标

def main():
    print(f"hello {os.getcwd()}")
    return [i ** 2 for i in range(10)]
