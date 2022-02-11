// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "../interfaces/curve/ICurve.sol";
import "../interfaces/uniswap/IUniswapRouterV2.sol";

import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";

contract MyStrategy is BaseStrategy {
// address public want; // Inherited from BaseStrategy
    // address public lpComponent; // Token that represents ownership in a pool, not always used
    // address public reward; // Token we farm

    address constant public BADGER = 0x3472A5A71965499acd81997a54BBA8D852C6E53d; 
    address constant public wETH = 0x74b23882a30290451A17c44f4F05243b6b58C76d;
    address constant public wBTC = 0x321162Cd933E2Be498Cd2267a90534A804051b11;
    // address constant public fUSDT; 

    address constant public CRV_REWARD = 0x1E4F97b9f9F913c46F1632781732927B9019C68b;
    address constant public WFTM_REWARD = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;


    // Curve interface contracts
    address constant public CURVE_ATRICRYPTO_POOL = 0x3a1659Ddcf2339Be3aeA159cA010979FB49155FF;
    // Curve.fi crv3crypto RewardGauge Deposit 
    address constant public CURVE_ATRICRYPTO_GAUGE = 0x00702BbDEaD24C40647f235F15971dB0867F6bdB; 
    address constant public SPOOKYSWAP_ROUTER = 0xF491e7B69E4244ad4002BC14e878a34207E38c29; 

    /// @dev Initialize the Strategy with security settings as well as tokens
    /// @notice Proxies will set any non constant variable you declare as default value
    /// @dev add any extra changeable variable at end of initializer as shown
    function initialize(address _vault, address[1] memory _wantConfig) public initializer {
        __BaseStrategy_init(_vault);
        /// @dev Add config here
        want = _wantConfig[0];
        
        // If you need to set new values that are not constants, set them like so
        // stakingContract = 0x79ba8b76F61Db3e7D994f7E384ba8f7870A043b7;

        // If you need to do one-off approvals do them here like so
        // IERC20Upgradeable(reward).safeApprove(
        //     address(DX_SWAP_ROUTER),
        //     type(uint256).max
        // );
        
        IERC20Upgradeable(want).safeApprove(CURVE_ATRICRYPTO_GAUGE, type(uint256).max);
        IERC20Upgradeable(wETH).safeApprove(CURVE_ATRICRYPTO_POOL, type(uint256).max);

        IERC20Upgradeable(CRV_REWARD).safeApprove(SPOOKYSWAP_ROUTER, type(uint256).max);
        IERC20Upgradeable(WFTM_REWARD).safeApprove(SPOOKYSWAP_ROUTER, type(uint256).max);

    }
    
    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "Curve-Tricrypto-Fantom-Strategy";
    }

    /// @dev Return a list of protected tokens
    /// @notice It's very important all tokens that are meant to be in the strategy to be marked as protected
    /// @notice this provides security guarantees to the depositors they can't be sweeped away
    function getProtectedTokens() public view virtual override returns (address[] memory) {
        address[] memory protectedTokens = new address[](2);
        protectedTokens[0] = want;
        protectedTokens[1] = BADGER;
        return protectedTokens;
    }

    /// @dev Deposit `_amount` of want, investing it to earn yield
    function _deposit(uint256 _amount) internal override {
        ICurveGauge(CURVE_ATRICRYPTO_GAUGE).deposit(_amount);
    }

    /// @dev Withdraw all funds, this is used for migrations, most of the time for emergency reasons
    function _withdrawAll() internal override {
        ICurveGauge(CURVE_ATRICRYPTO_GAUGE).withdraw(balanceOfPool());
    }

    /// @dev Withdraw `_amount` of want, so that it can be sent to the vault / depositor
    /// @notice just unlock the funds and return the amount you could unlock
    function _withdrawSome(uint256 _amount) internal override returns (uint256) {
        if(_amount > balanceOfPool()) {
            _amount = balanceOfPool();
        }

        ICurveGauge(CURVE_ATRICRYPTO_GAUGE).withdraw(_amount);

        return _amount;
    }


    /// @dev Does this function require `tend` to be called?
    function _isTendable() internal override pure returns (bool) {
        return true;
    }

    function _harvest() internal override returns (TokenAmount[] memory harvested) {
        // No-op as we don't do anything with funds
        // use autoCompoundRatio here to convert rewards to want ...
        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        // figure out and claim our rewards
        ICurveGauge(CURVE_ATRICRYPTO_GAUGE).claim_rewards();

        // Get total rewards (wFTM & CRV)
        uint256 wftmAmount = IERC20Upgradeable(WFTM_REWARD).balanceOf(address(this));
        uint256 crvAmount = IERC20Upgradeable(CRV_REWARD).balanceOf(address(this));

        
        // If no reward, then no-op
        if (wftmAmount == 0 && crvAmount == 0) {
            return new TokenAmount[](1);
        }

        /*
            We want to swap rewards (wFTM & CRV) to wETH 
            and then add liquidity to tricrypto pool by depositing wETH
        */

        // Swap CRV to wFTM (most liquidity)
        if (crvAmount > 0) {
            address[] memory path = new address[](2);
            path[0] = CRV_REWARD; 
            path[1] = WFTM_REWARD;
            IUniswapRouterV2(SPOOKYSWAP_ROUTER).swapExactTokensForTokens(crvAmount, 0, path, address(this), now);
        }

        // Swap wFTM to wETH
        if (wftmAmount > 0) {
            address[] memory path = new address[](2);
            path[0] = WFTM_REWARD; 
            path[1] = wETH;
            IUniswapRouterV2(SPOOKYSWAP_ROUTER).swapExactTokensForTokens(wftmAmount, 0, path, address(this), now);
        }

        // Add liquidity for tricrypto pool by depositing wETH
        ICurveFi(CURVE_ATRICRYPTO_POOL).add_liquidity(
            [IERC20Upgradeable(wETH).balanceOf(address(this)), 0], 0, true
        );


        uint256 earned = IERC20Upgradeable(want).balanceOf(address(this)).sub(_before);

        // Nothing harvested, we have 2 tokens, return both 0s
        harvested = new TokenAmount[](1);
        harvested[0] = TokenAmount(want, earned);

        // keep this to get paid!
        _reportToVault(earned);

        return harvested;
    }


    // Example tend is a no-op which returns the values, could also just revert
    function _tend() internal override returns (TokenAmount[] memory tended){
        uint256 _amount = balanceOfWant();
        if (_amount > 0) {
            _deposit(_amount);
        }

        tended = new TokenAmount[](1);
        tended[0] = TokenAmount(want, _amount);
        return tended;
    }

    /// @dev Return the balance (in want) that the strategy has invested somewhere
    function balanceOfPool() public view override returns (uint256) {
        return IERC20Upgradeable(CURVE_ATRICRYPTO_GAUGE).balanceOf(address(this));
    }

    /// @dev Return the balance of rewards that the strategy has accrued
    /// @notice Used for offChain APY and Harvest Health monitoring
    function balanceOfRewards() external view override returns (TokenAmount[] memory rewards) {
        // Rewards are 0
        rewards = new TokenAmount[](2);
        rewards[0] = TokenAmount(want, 0);
        rewards[1] = TokenAmount(BADGER, 0); 
        return rewards;
    }
}
