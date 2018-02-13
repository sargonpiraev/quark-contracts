pragma solidity 0.4.19;

import "./token/ERC20/ERC20Basic.sol";
import "./token/ERC20/ERC20.sol";
import "./token/ERC20/MintableToken.sol";
import "./token/ERC20/ERC20.sol";
import "./token/Ownable.sol";
import "./contracts/ReentrancyGuard.sol";


contract QRMToken is MintableToken {
    string public constant NAME = " QUARK MARKET ";

    string public constant SYMBOL = "BSE";

    uint32 public constant DECIMALS = 18;

    event Burn(address indexed burner, uint256 value);

  /**
   * @dev Burns a specific amount of tokens.
   * @param _value The amount of token to be burned.
   */
    function burn(uint256 _value) public {
        require(_value > 0);
        require(_value <= balances[msg.sender]);
        // no need to require value <= totalSupply, since that would imply the
        // sender's balance is greater than the totalSupply, which *should* be an assertion failure

        address burner = msg.sender;
        balances[burner] = balances[burner].sub(_value);
        totalSupply = totalSupply.sub(_value);
        Burn(burner, _value);
    }

}


contract Stateful {
    enum State {
        Init,
        PreIco,
        PreIcoPaused,
        preIcoFinished,
        ICO,
        salePaused,
        CrowdsaleFinished,
        companySold
    }

    State public state = State.Init;

    event StateChanged(State oldState, State newState);

    function setState(State newState) internal {
        State oldState = state;
        state = newState;
        StateChanged(oldState, newState);
    }
}


contract FiatContract {
    function fETH(uint _id) public view returns (uint256);
    function fUSD(uint _id) public view returns (uint256);
    function fEUR(uint _id) public view returns (uint256);
    function fGBP(uint _id) public view returns (uint256);
    function updatedAt(uint _id)  public view returns (uint);
}


contract Crowdsale is Ownable, ReentrancyGuard, Stateful {

    using SafeMath for uint;

    function Crowdsale(address _multisig) {
        multisig = _multisig;
        token = new QRMToken();
    }

    function () public payable {mintTokens();}

    mapping (address => uint) preICOinvestors;
    mapping (address => uint) iICOinvestors;

    QRMToken public token;
    uint256 public startICO;
    uint256 public startPreICO;
    uint256 public period;
    uint256 public constant RATE_CENT = 2000000000000000;
    uint256 public constant PRE_ICO_TOKEN_HARDCAP = 440000 * 1 ether;
    uint256 public constant ICO_TOKEN_HARDCAP = 1540000 * 1 ether;
    uint256 public collectedCent;
    uint256 day = 86400; // sec in day
    uint256 public soldTokens;

    address multisig;

    //TODO разобраться что за фиатный контракт
    FiatContract public price = FiatContract(0x2CDe56E5c8235D6360CCbb0c57Ce248Ca9C80909);
    // mainnet 0x8055d0504666e2B6942BeB8D6014c964658Ca591
    // testnet 0x2CDe56E5c8235D6360CCbb0c57Ce248Ca9C80909

    modifier saleIsOn() {
        require((state == State.PreIco || state == State.ICO)
        &&(now < startICO + period || now < startPreICO + period));
        _;
    }

    modifier isUnderHardCap() {
        require(soldTokens < getHardcap());
        _;
    }

    function startCompanySell() onlyOwner {
        require(state == State.CrowdsaleFinished);
        setState(State.companySold);
    }

  // for mint tokens to USD investor
    function usdSale(address _to, uint _valueUSD) onlyOwner {
        uint256 valueCent = _valueUSD * 100;
        uint256 tokensAmount = RATE_CENT.mul(valueCent);
        collectedCent += valueCent;
        token.mint(_to, tokensAmount);
        if (state == State.ICO || state == State.preIcoFinished) {
            iICOinvestors[_to] += tokensAmount;
        } else {
            preICOinvestors[_to] += tokensAmount;
        }
        soldTokens += tokensAmount;
    }

    function pauseSale() onlyOwner {
        require(state == State.ICO);
        setState(State.salePaused);
    }

    function pausePreSale() onlyOwner {
        require(state == State.PreIco);
        setState(State.PreIcoPaused);
    }

    function startPreIco(uint256 _period) onlyOwner {
        require(_period != 0);
        require(state == State.Init || state == State.PreIcoPaused);
        startPreICO = now;
        period = _period * day;
        setState(State.PreIco);
    }

    function finishPreIco() onlyOwner {
        require(state == State.PreIco);
        setState(State.preIcoFinished);
        bool isSent = multisig.call.gas(3000000).value(this.balance)();
        require(isSent);
    }

    function startIco(uint256 _period) onlyOwner {
        require(_period != 0);
        startICO = now;
        period = _period * day;
        setState(State.ICO);
    }

    function finishICO() onlyOwner {
        require(state == State.ICO);
        setState(State.CrowdsaleFinished);
        bool isSent = multisig.call.gas(3000000).value(this.balance)();
        require(isSent);
    }

    function finishMinting() onlyOwner {

        token.finishMinting();

    }

    function getDouble() nonReentrant {
        require(state == State.ICO || state == State.companySold);
        uint256 extraTokensAmount;
        if (state == State.ICO) {
            extraTokensAmount = preICOinvestors[msg.sender];
            preICOinvestors[msg.sender] = 0;
            token.mint(msg.sender, extraTokensAmount);
            iICOinvestors[msg.sender] += extraTokensAmount;
        }else {
            if (state == State.companySold) {
                extraTokensAmount = preICOinvestors[msg.sender] + iICOinvestors[msg.sender];
                preICOinvestors[msg.sender] = 0;
                iICOinvestors[msg.sender] = 0;
                token.mint(msg.sender, extraTokensAmount);
            }
        }
    }

    function getHardcap() returns(uint256) {
        if (state == State.PreIco) {
            return PRE_ICO_TOKEN_HARDCAP;
        }else {
            if (state == State.ICO) {
                return ICO_TOKEN_HARDCAP;
            }
        }
    }

    function mintTokens() public payable saleIsOn isUnderHardCap nonReentrant {
        uint256 valueWEI = msg.value;
        uint256 priceUSD = price.iUSD(0);
        uint256 valueCent = valueWEI.div(priceUSD);
        uint256 tokens = RATE_CENT.mul(valueCent);
        uint256 hardcap = getHardcap();
        if (soldTokens + tokens > hardcap) {
            tokens = hardcap.sub(soldTokens);
            valueCent = tokens.div(RATE_CENT);
            valueWEI = valueCent.mul(priceUSD);
            uint256 change = msg.value - valueWEI;
            bool isSent = msg.sender.call.gas(30000000).value(change)();
            require(isSent);
        }
        token.mint(msg.sender, tokens);
        collectedCent += valueCent;
        soldTokens += tokens;
        if (state == State.PreIco) {
            preICOinvestors[msg.sender] += tokens;
        } else {
            iICOinvestors[msg.sender] += tokens;
        }
    }

}
