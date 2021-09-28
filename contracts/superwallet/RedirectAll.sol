// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import {
    ISuperfluid,
    ISuperToken,
    ISuperApp,
    ISuperAgreement,
    SuperAppDefinitions
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
// When ready to move to leave Remix, change imports to follow this pattern:
// "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {
    IConstantFlowAgreementV1
} from "@superfluid-finance/protocol-monorepo/blob/remix-support/packages/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import {
    SuperAppBase
} from "@superfluid-finance/protocol-monorepo/blob/remix-support/packages/ethereum-contracts/contracts/apps/SuperAppBase.sol";


import "@Uniswap/uniswap-v3-periphery/blob/main/contracts/interfaces/ISwapRouter.sol";

// Interfaces

interface IERC20 {
    function transfer(address _to, uint256 _amount) external returns (bool);
    function totalSupply() external view returns (uint);
    function balanceOf(address account) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);
    function approve(address spender, uint amount) external returns (bool);
    function transferFrom(
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
}

interface IUniswapV3Router {
  
}

interface IUniswapV2Pair {
  function token0() external view returns (address);
  function token1() external view returns (address);
  function swap(
    uint256 amount0Out,
    uint256 amount1Out,
    address to,
    bytes calldata data
  ) external;
}

interface IUniswapV2Factory {
  function getPair(address token0, address token1) external returns (address);
}

contract RedirectAll is SuperAppBase {

    ISuperfluid private _host; // host
    IConstantFlowAgreementV1 private _cfa; // the stored constant flow agreement class address
    ISuperToken private _acceptedToken; // accepted token
    address private _receiver;
    bool public afterAgreementCreatedState = false;
    
    

    constructor(
        ISuperfluid host,
        IConstantFlowAgreementV1 cfa,
        ISuperToken acceptedToken,
        address receiver) {
        assert(address(host) != address(0));
        assert(address(cfa) != address(0));
        assert(address(acceptedToken) != address(0));
        assert(address(receiver) != address(0));
        //assert(!_host.isApp(ISuperApp(receiver)));

        _host = host;
        _cfa = cfa;
        _acceptedToken = acceptedToken;
        _receiver = receiver;

        uint256 configWord =
            SuperAppDefinitions.APP_LEVEL_FINAL |
            SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

        _host.registerApp(configWord);
    }

    /**************************************************************************
     * Redirect Logic
     *************************************************************************/

    function currentReceiver()
        external view
        returns (
            uint256 startTime,
            address receiver,
            int96 flowRate
        )
    {
        if (_receiver != address(0)) {
            (startTime, flowRate,,) = _cfa.getFlow(_acceptedToken, address(this), _receiver);
            receiver = _receiver;
        }
    }
    
    function getBalance()
        external view
        returns (
            address receiver,
            int256 availableBalance
        )
    {
        if (_receiver != address(0)) {
            (availableBalance,,) = _cfa.realtimeBalanceOf(_acceptedToken, address(this), block.timestamp);
            receiver = _receiver;
        }
    }
    

    event ReceiverChanged(address receiver); //what is this?

    /// @dev If a new stream is opened, or an existing one is opened
    function _updateOutflow(bytes calldata ctx)
        private
        returns (bytes memory newCtx)
    {
      if(afterAgreementCreatedState == false) {
      newCtx = ctx;
      } else {
          newCtx = ctx;
          // @dev This will give me the new flowRate, as it is called in after callbacks
          int96 netFlowRate = _cfa.getNetFlow(_acceptedToken, address(this));
          (,int96 outFlowRate,,) = _cfa.getFlow(_acceptedToken, address(this), _receiver);
          int96 inFlowRate = netFlowRate + outFlowRate;
          if (inFlowRate < 0 ) inFlowRate = -inFlowRate; // Fixes issue when inFlowRate is negative
    
          // @dev If inFlowRate === 0, then delete existing flow.
          if (outFlowRate != int96(0)){
            (newCtx, ) = _host.callAgreementWithContext(
                _cfa,
                abi.encodeWithSelector(
                    _cfa.updateFlow.selector,
                    _acceptedToken,
                    _receiver,
                    inFlowRate,
                    new bytes(0) // placeholder
                ),
                "0x",
                newCtx
            );
          } else if (inFlowRate == int96(0)) {
            // @dev if inFlowRate is zero, delete outflow.
              (newCtx, ) = _host.callAgreementWithContext(
                  _cfa,
                  abi.encodeWithSelector(
                      _cfa.deleteFlow.selector,
                      _acceptedToken,
                      address(this),
                      _receiver,
                      new bytes(0) // placeholder
                  ),
                  "0x",
                  newCtx
              );
          } else {
          // @dev If there is no existing outflow, then create new flow to equal inflow
              (newCtx, ) = _host.callAgreementWithContext(
                  _cfa,
                  abi.encodeWithSelector(
                      _cfa.createFlow.selector,
                      _acceptedToken,
                      _receiver,
                      inFlowRate,
                      new bytes(0) // placeholder
                  ),
                  "0x",
                  newCtx
              );
          }
      }
    }

    /**************************************************************************
     * SuperApp callbacks
     *************************************************************************/
    
    // receives incoming flow without opening up new one to the NFT holder.
    function afterAgreementCreated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata /*_agreementData*/,
        bytes calldata ,// _cbdata,
        bytes calldata _ctx
    )
        external override
        onlyExpected(_superToken, _agreementClass)
        onlyHost
        returns (bytes memory newCtx)
    {
        return _updateOutflow(_ctx);
    }

    function afterAgreementUpdated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32 ,//_agreementId,
        bytes calldata /*_agreementData*/,
        bytes calldata ,//_cbdata,
        bytes calldata _ctx
    )
        external override
        onlyExpected(_superToken, _agreementClass)
        onlyHost
        returns (bytes memory newCtx)
    {
        return _updateOutflow(_ctx);
    }

    function afterAgreementTerminated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32 ,//_agreementId,
        bytes calldata /*_agreementData*/,
        bytes calldata ,//_cbdata,
        bytes calldata _ctx
    )
        external override
        onlyHost
        returns (bytes memory newCtx)
    {
        // According to the app basic law, we should never revert in a termination callback
        if (!_isSameToken(_superToken) || !_isCFAv1(_agreementClass)) return _ctx;
        return _updateOutflow(_ctx);
    }

    function _isSameToken(ISuperToken superToken) private view returns (bool) {
        return address(superToken) == address(_acceptedToken);
    }

    function _isCFAv1(address agreementClass) private view returns (bool) {
        return ISuperAgreement(agreementClass).agreementType()
            == keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
    }

    modifier onlyHost() {
        require(msg.sender == address(_host), "RedirectAll: support only one host");
        _;
    }

    modifier onlyExpected(ISuperToken superToken, address agreementClass) {
        require(_isSameToken(superToken), "RedirectAll: not accepted token");
        require(_isCFAv1(agreementClass), "RedirectAll: only CFAv1 supported");
        _;
    }
    
    /**************************************************************************
     * Added Functions
     *************************************************************************/
    
    function withdraw(address _tokenContract, uint256 _amount) public {
        IERC20 tokenContract = IERC20(_tokenContract);
        require(msg.sender == _receiver);
        tokenContract.transfer(msg.sender, _amount /** 10**18*/);
    }
    
    function withdrawContract(address _tokenContract, uint256 _amount) private {
        IERC20 tokenContract = IERC20(_tokenContract);
        require(msg.sender == _receiver);
        tokenContract.transfer(_tokenContract, _amount /** 10**18*/);
    }
    
     //address of the uniswap v2 router
    //address private constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    ISwapRouter private constant uniswapRouter = ISwapRouter(UNISWAP_V3_ROUTER);
    
    //address of WETH token.  This is needed because some times it is better to trade through WETH.  
    //you might get a better price using WETH.  
    //example trading from token A to WETH then WETH to token B might result in a better price
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    //this swap function is used to trade from one token to another
    //the inputs are self explainatory
    //token in = the token address you want to trade out of
    //token out = the token address you want as the output of this trade
    //amount in = the amount of tokens you are sending in
    //amount out Min = the minimum amount of tokens you want out of the trade
    //to = the address you want the tokens to be sent to
    
    
   function swap(address _tokenIn, address _tokenOut, uint256 _amountIn) external payable {
      
        require(msg.sender == _receiver);
        //next we need to allow the uniswapv2 router to spend the token we just sent to this contract
        //by calling IERC20 approve you allow the uniswap contract to spend the tokens in this contract 
        IERC20(_tokenIn).approve(UNISWAP_V3_ROUTER, _amountIn);
        
        uint256 deadline = block.timestamp + 15; // using 'now' for convenience, for mainnet pass deadline from frontend!
        address tokenIn = _tokenIn;
        address tokenOut = _tokenOut;
        uint24 fee = 10000;
        address recipient = msg.sender;
        uint256 amountIn = _amountIn;
        uint256 amountOutMinimum = 1;
        uint160 sqrtPriceLimitX96 = 0;
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
            tokenIn,
            tokenOut,
            fee,
            recipient,
            deadline,
            amountIn,
            amountOutMinimum,
            sqrtPriceLimitX96
        );
        
        uniswapRouter.exactInputSingle(params);
    }
    
    
    
    /*function withdrawUni(address _tokenContract, uint256 _amount) public {
        IERC20 tokenContract = IERC20(_tokenContract);
        
        require(msg.sender == _receiver);
    }
    
    function withdrawAave(address _tokenContract, uint256 _amount) public {
        IERC20 tokenContract = IERC20(_tokenContract);
        
        require(msg.sender == _receiver);
    }*/
}
