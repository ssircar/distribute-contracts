pragma solidity ^0.4.8;

import "./library/StandardToken.sol";
import "./TokenRegistry.sol";

contract DistributeToken is StandardToken {
  TokenRegistry tokenRegistry;
  /*address trAddress;*/

  string public constant symbol = "DST";
  string public constant name = "Distributed Utility Token";
  uint8 public constant decimals = 18;

  uint256 public totalSupply = 0;               //total supply of capital tokens in all staking states
  uint256 public totalFreeSupply = 0;           //total supply of free capital tokens (not staked, validated, or voted)

  uint256 public weiBal;

  // .0001 ether --> 3 cents
  uint256 baseCost = 100000000000000;

 // =====================================================================
 // EVENTS
 // =====================================================================

   event LogMint(uint256 amountMinted, uint256 totalCost);
   event LogWithdraw(uint256 amountWithdrawn, uint256 reward);

   // =====================================================================
   // CONSTRUCTOR
   // =====================================================================
   function DistributeToken(address _tokenRegistry) public {
     require(address(tokenRegistry) == 0);
     tokenRegistry = TokenRegistry(_tokenRegistry);
   }
 // =====================================================================
 // MODIFIERS
 // =====================================================================

 modifier onlyTR() {
   require(msg.sender == address(tokenRegistry));
   _;
 }

 // =====================================================================
 // INFO FUNCTIONS
 // =====================================================================
 function currentPrice() public view returns (uint256) {
   //calculated current burn reward of 1 token at current weiBal and free token supply
   if (totalFreeSupply == 0) {
     return baseCost;
   } else {
   return weiBal / totalFreeSupply; //truncation - remainder discarded
   }
 }

 // =====================================================================
 // TRANSFER FUNCTIONS
 // =====================================================================

 function transferWeiFrom(address _address, uint256 _weiValue) public onlyTR() {
   weiBal -= _weiValue;
   _address.transfer(_weiValue);
 }
 function transferWeiTo() public payable {
   weiBal += msg.value;
 }

 function transferToEscrow(address _owner, uint256 _value) public onlyTR() returns (bool) {
   require(balances[_owner] >= _value);
   balances[_owner] -= _value;
   totalFreeSupply -= _value;
   balances[msg.sender] += _value;
   return true;
 }

 function transferFromEscrow(address _owner, uint256 _value) public onlyTR() returns (bool) {
   require(balances[msg.sender] >= _value);
   balances[msg.sender] -= _value;
   totalFreeSupply += _value;
   balances[_owner] += _value;
   return true;
 }

  // =====================================================================
  // MINTING FUNCTIONS
  // =====================================================================

  function mint(uint _tokens) public payable {
      uint256 targetPriceVal;
      /*
        if total supply is 0 or the currentPrice is 0
        return the baseCost, otherwise return the calculated
        targetPrice.
      */
      if (totalSupply == 0 || currentPrice() == 0) {
        targetPriceVal = baseCost;
      } else {
        targetPriceVal = targetPrice(_tokens);
      }
      // calculate the amount of wei required to create the tokens
      uint256 weiRequiredVal = weiRequired(targetPriceVal, _tokens);
      require(msg.value >= weiRequiredVal);

      totalSupply += _tokens;
      totalFreeSupply += _tokens;
      balances[msg.sender] += _tokens;

      weiBal += weiRequiredVal;
      LogMint(_tokens, weiRequiredVal);

      // return any excess ether as change in wei
      uint256 fundsLeft = msg.value - weiRequiredVal;
      if (fundsLeft > 0) {
        msg.sender.transfer(fundsLeft);
      }
  }
  // =====================================================================
  // BURN FUNCTIONS
  // =====================================================================

  function percent(uint256 numerator, uint256 denominator, uint256 precision) internal pure returns (uint256) {
     // caution, check safe-to-multiply here
    uint256 _numerator  = numerator * 10 ** (precision+1);
    // with rounding of last digit
    uint256 _quotient =  ((_numerator / denominator) + 5) / 10;
    return _quotient;
  }

  function weiRequired(uint256 _targetPrice, uint256 _tokens) public view returns (uint256) {
    return ((_targetPrice * (totalSupply + _tokens)) - currentPrice() * totalSupply);
  }

  function targetPrice(uint _tokens) public view returns (uint256) {
    uint256 newSupply = totalSupply + _tokens;
    uint256 cp = currentPrice();
    return cp * (1000 + percent(_tokens, newSupply, 3)) / 1000;
  }

  function burnTokens(uint256 _amountToBurn) public onlyTR() {
    totalSupply -= _amountToBurn;
  }

  function burnAndRefundTokens(uint256 _amountToBurn) public {      //free tokens only
      require(_amountToBurn > 0 && (balances[msg.sender]) >= _amountToBurn);
      //determine how much you can leave with.
      uint256 reward = _amountToBurn * currentPrice();    //truncation - remainder discarded
      balances[msg.sender] -= _amountToBurn;
      totalSupply -= _amountToBurn;
      totalFreeSupply -= _amountToBurn;
      weiBal -= reward;
      LogWithdraw(_amountToBurn, reward);
      msg.sender.transfer(reward);
  }

  function() public payable {
    /*weiBal += msg.value;*/
  }
}